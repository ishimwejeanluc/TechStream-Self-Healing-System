# Grafana Cloud Machine Learning setup

Replaces the hand-rolled `rca/rca.py` as the AI/ML root cause artifact with a real
tool. `rca.py` stays as the offline fallback and as a comparison, it is not
deleted.

Grafana Cloud ML was chosen over Amazon DevOps Guru for one concrete reason:
DevOps Guru reads CloudWatch, and this lab's application errors live in
Prometheus. For the incident this lab actually remediates, host CPU peaked at
15.8 percent while 771 requests failed. DevOps Guru would have reported nothing.

This document is the Terraform path, which is the primary one. The UI walkthrough
and the API script are alternatives further down.

## Status

| Step | State |
|---|---|
| 1. Ship metrics with remote_write | Done, waiting on a real token |
| 2. ML jobs as Terraform in `infra/grafana-ml/` | Not started |
| 3. Remediation loop unchanged | Unchanged by design |
| 4. Sift investigation as the RCA artifact | Not started |

## Stack details

Non-secret, safe to keep in the repo.

| Item | Value |
|---|---|
| Remote write endpoint | `https://prometheus-prod-67-prod-us-west-0.grafana.net/api/prom/push` |
| Query endpoint | `https://prometheus-prod-67-prod-us-west-0.grafana.net/api/prom` |
| Username, numeric instance ID | `3508250` |
| Stack URL | `https://largedingo3143.grafana.net` |
| Cluster and region | `prod-us-west-0`, `mimir-prod-67`, AWS `us-west-2` |

## Two tokens, from two different places

This is the part that trips people up. They are not interchangeable.

| | Token 1, remote_write | Token 2, Terraform |
|---|---|---|
| Created in | grafana.com Cloud Portal | your Grafana instance |
| Under | Access Policies, scope `metrics:write` | Administration, Users and access, Service accounts |
| Prefix | `glc_` | `glsa_` |
| Used by | Prometheus `remote_write` | the `grafana` Terraform provider |
| Stored in | `monitoring/prometheus/grafana_cloud_token` | `infra/grafana-ml/terraform.tfvars` |

Both paths are gitignored. If a token starts with `glc_` where `glsa_` is
expected, it cannot create ML jobs, and vice versa.

The service account needs at least the Editor role. Grafana's own docs state
"Editor or Admin basic role" is required to create forecasts. Admin is the safer
choice, because Step 2 also provisions an outlier detector and optionally alert
rules, and a 403 part way through `terraform apply` leaves half-created jobs to
clean up by hand.

Deleting the service account revokes every token it issued, which is the kill
switch and belongs in teardown.

## Step 1: remote_write

Already applied to `monitoring/prometheus/prometheus.yml`. Local scraping and
local alerting are untouched. remote_write is an additional fan-out, so if
Grafana Cloud is unreachable, Prometheus keeps scraping and the self-healing loop
keeps working.

### The token is not in the config file

Prometheus does not expand environment variables in `prometheus.yml`, so the
usual `.env` trick does not work here. It uses `password_file` instead, the same
pattern Alertmanager already uses for its webhook URL:

```yaml
basic_auth:
  username: "3508250"
  password_file: /etc/prometheus/grafana_cloud_token
```

Write the token with:

```bash
make cloud-token TOKEN=glc_...
make cloud-status
```

### The allowlist, and why it matters

The free tier allows 10000 active series. This stack carries about 3600, but only
a fraction is useful to an ML job. Measured against the real series list:

| | Series |
|---|---|
| Total local | 3649 |
| Shipped after the allowlist | **121** |
| Dropped | 3528 |

The 3528 dropped are node-exporter internals, Prometheus self-monitoring and
Alertmanager internals that no dashboard panel, alert rule or ML job queries.
Shipping them would consume the allowance and slow training for nothing.

Everything kept is used by a panel, a rule or an ML job. If you add a panel that
needs a new metric, add it to the allowlist too, or it will work locally and be
silently missing in Grafana Cloud.

### Only our containers

cAdvisor reports every container on the Docker host, not just this compose
project. On the development machine that included containers from unrelated
projects. Those are filtered out before shipping, so the DBSCAN outlier detector
compares this app against its own siblings rather than against someone else's
workload.

That filter is expressed as a positive alternation, not a negative lookahead,
because Prometheus relabelling uses Go's RE2 engine and RE2 has no lookahead at
all. A config using `(?!techstream-)` is silently wrong.

### Verifying it works

```bash
make cloud-status
```

With the placeholder token in place, the expected and correct output is a 401:

```
component=remote remote_name=grafana-cloud msg="non-recoverable error"
  failedSampleCount=42
  err="server returned HTTP status 401 Unauthorized:
       {\"status\":\"error\",\"error\":\"authentication error: invalid token\"}"
```

That 401 is useful. It proves four things at once: the network path to Grafana
Cloud works, the endpoint and username are the right shape (a wrong URL gives 404,
not 401), the allowlist is working (about 40 samples per batch rather than
thousands), and Prometheus itself is unharmed.

Confirmed after the config was loaded: all five scrape targets still up, all four
alert rules still evaluating. A broken remote_write does not break the lab.

Once the real token is in place, that error stops and Active Series in the Cloud
Portal climbs off 0.

## Gotchas that will bite you

### Models need a training window before any chaos test

This is the important one. An anomaly or forecast model learns what normal looks
like from the data it has. If chaos runs during the training window, the model
learns that a 40 percent error rate is normal and will not flag it later.

After the token is live:

```bash
make traffic DURATION=600 RPS=20     # at least a few minutes of healthy traffic
```

Only then run `make chaos-errors`. Check the job shows as trained and healthy in
the Grafana ML UI before trusting any anomaly score.

### The error ratio query needs `or vector(0)` for ML, unlike everywhere else

The error ratio expression the dashboard and alert share returns **empty, not
zero**, when no 5xx exists. Measured on a healthy app:

```
100 * sum(rate(http_requests_total{status=~"5.."}[1m])) / clamp_min(...)   -> EMPTY
same expression with `or vector(0)` appended                               -> 0
```

For alerting, empty is correct behaviour, which is why the alert rule is left
alone. For a forecasting model it is fatal: you cannot train on a series that
does not exist most of the time. The ML job therefore appends `or vector(0)`.

Same query, one suffix, different consumer. This is the one place the project
deliberately does not reuse the expression verbatim, and the reason is recorded
here so it does not look like an inconsistency.

### ML alert queries must be concrete

Grafana evaluates alert rules without dashboard context, so template variables
like `$instance` and `$job` are not resolved. Queries in ML jobs and in
Grafana-managed alert rules have to be fully written out.

This lab is unaffected, because its existing queries use no such variables. The
dashboard's `${datasource}` variable is a datasource selector, not a label, and
does not appear in any ML job.

### Self-hosted Grafana would need the paid ML plugin

This setup assumes Grafana Cloud, where forecasting, outlier detection and Sift
are available on the free tier. The Cloud pricing page describes Free as "all
Grafana Cloud services, with limited usage", and the ML docs state no plan gate,
but no page found during setup confirms ML specifically on the free tier. If job
creation returns a permission or plan error, that is the reason.

The local Grafana container in this repo is only used for the Golden Signals
dashboard. It does not run ML.

## Teardown

`infra/grafana-ml/` is destroyed independently of the AWS stack. They share the
state bucket but use different keys, different providers and different
credentials.

```bash
terraform -chdir=infra/grafana-ml destroy    # ML jobs only
make tf-destroy                              # AWS stack
```

Then delete the `terraform-techstream-ml` service account in Grafana, which
revokes its token.

The bootstrap state bucket is destroyed **last**, because it holds the state for
both of the above. See the runbook for the full sequence.

To stop shipping metrics without destroying anything, delete the `remote_write`
block from `monitoring/prometheus/prometheus.yml` and reload, or revoke the
`glc_` token in the Cloud Portal.
