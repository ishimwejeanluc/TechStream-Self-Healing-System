# Step 5: Alerting and automated remediation

Files: `monitoring/prometheus/rules/alerts.yml`,
`monitoring/alertmanager/alertmanager.yml`, `remediator/` (local stand-in),
and the Lambda from Step 1 at `infra/modules/remediation/`.

## The chain

```
Prometheus rule HighErrorRate fires
  -> Alertmanager routes it (only this alertname)
    -> webhook POST with a shared token
      -> Lambda validates, filters, calls SSM SendCommand      [deployed path]
      -> or local remediator restarts via the Docker API       [local path]
        -> app container restarts, in-memory chaos state clears
          -> error ratio falls, alert resolves
```

## The alert rule

```yaml
- alert: HighErrorRate
  expr: >-
    100 * sum(rate(http_requests_total{status=~"5.."}[1m]))
    / clamp_min(sum(rate(http_requests_total[1m])), 1) > 5
  for: 1m
  labels:
    severity: critical
    app: techstream-web
    remediation: restart
  annotations:
    summary: "Error ratio above 5 percent on techstream-web"
    ratio: '{{ $value | printf "%.2f" }}'
```

The expression is character for character the one the Grafana error ratio panel
draws, so the line you watch and the line that restarts the app are the same
computation. They cannot disagree.

`for: 1m` means the ratio has to hold above 5 percent across four consecutive 15
second evaluations. One bad scrape does not restart anything.

`app` is in the labels and `ratio` is in the annotations, as required. The
remediator logs the ratio next to the restart, so the record says how bad it was.

### Three more rules

| Alert | For | Remediation | Why |
|---|---|---|---|
| `HighErrorRate` | 1m | restart | The one wired to automation |
| `AppDown` | 2m | none | Closes a gap described below |
| `HighLatencyP95` | 2m | none | A restart does not fix a slow host |
| `HostCpuSaturation` | 2m | none | Scaling out is the answer, not a restart |

`HighLatencyP95` was originally set at 0.5s. Step 6 measured the app's idle p95
at about 0.07s and its saturated p95 at about 0.25s, which made 0.5s a 7x
regression before anything would say so. It is now 0.2s, roughly 3x normal.

The three observation-only alerts also prove the routing tree works: they exist,
they fire, and they never reach the remediation webhook.

## Routing is fail closed

```yaml
route:
  receiver: null-receiver        # default
  routes:
    - matchers: [alertname="HighErrorRate"]
      receiver: remediation-webhook
      group_wait: 0s
      repeat_interval: 10m
```

The default receiver is the null receiver, so a new alert has to be routed to
remediation deliberately. It cannot inherit the webhook by accident and start
restarting the app for something a restart cannot fix.

Verified with `amtool`:

```
$ amtool config routes test alertname=HighErrorRate      -> remediation-webhook
$ amtool config routes test alertname=AppDown            -> null-receiver
$ amtool config routes test alertname=HostCpuSaturation  -> null-receiver
```

`group_wait: 0s` on the remediation route means the webhook fires as soon as the
rule does, rather than adding another 10 seconds on top of the rule's own
`for: 1m`.

`repeat_interval: 10m` is the real guard against restart storms. If the alert is
still firing 10 minutes after a restart, the restart did not fix it and a second
attempt is reasonable. The in-memory throttle in the Lambda and the remediator
only holds while the process stays warm, so this is what actually bounds how
often the app gets restarted.

An inhibit rule suppresses `HighLatencyP95` while `HighErrorRate` is firing. A
failing app is usually a slow app, and the error alert is the actionable one.

## Keeping the token out of git

The webhook URL carries a shared secret, so it is not in the committed config.
Alertmanager reads it at notify time:

```yaml
webhook_configs:
  - url_file: /etc/alertmanager/webhook_url
    send_resolved: true
```

`monitoring/alertmanager/webhook_url` is gitignored and written by
`make configure URL=...`. Confirmed that Alertmanager validates this config even
when the file does not exist, so the stack starts fine before remediation is
configured:

```
$ amtool check-config am.yml     # with webhook_url absent
Checking 'am.yml'  SUCCESS
```

Until it is configured, a firing alert logs a notify error. That is the expected
state, not a fault.

## The two remediation paths

### Deployed path: Lambda plus SSM

Built in Step 1. The Lambda validates the token, filters per alert on
`status == firing`, checks the alertname, then calls `ssm:SendCommand` against a
custom document scoped to one instance. It logs the command ID and returns 200.

### Local path: the remediator stand-in

`remediator/app.py` exists because the deployed path cannot be tested without
applying Terraform. It accepts the same payload, applies the same checks in the
same order, and performs the same logical action. Only the mechanism differs:

| | Deployed | Local |
|---|---|---|
| Trigger | Alertmanager webhook | Alertmanager webhook |
| Auth | `?token=` with `hmac.compare_digest` | identical |
| Firing filter | per alert, not per batch | identical |
| Alertname gate | `HighErrorRate` only | identical |
| Throttle | in-memory, best effort | identical |
| Action | SSM SendCommand to a scoped document | Docker API container restart |
| Result | `docker compose restart app` | container restart |

The decision logic is duplicated deliberately so a loop proven locally is the
same loop that runs on EC2. If you change one, change the other.

**It mounts the Docker socket, which is root equivalent on the host.** That is
why it sits behind a compose profile and never starts with a plain
`docker compose up -d`:

```bash
docker compose --profile local-remediation up -d
```

Never enable this profile on the instance. The deployed path achieves the same
outcome with a scoped IAM policy and no socket exposure. If something like it
were ever needed in a shared environment, it should sit behind a socket proxy
allowing only the restart endpoint.

## The verified loop, with real timestamps

Run on 2026-08-17. `chaos.sh errors 120 --recovery 240 --rps 12`, no human
intervention after the chaos script started.

| Time (UTC) | Event | Evidence |
|---|---|---|
| 12:34:00 | Chaos run starts, error rate set to 0.4 | `incident.json` `started_at` |
| 12:34:21 | Error ratio measured at 42.13 percent, rule still inactive | timeline |
| 12:34:39 | Rule enters **pending**, the `for: 1m` clock starts | timeline |
| 12:35:34.55 | Rule enters **firing**, ratio 41.67 percent | alert `startsAt` |
| 12:35:34.81 | Alertmanager delivers the webhook, remediator accepts it | remediator log |
| 12:35:34.81 | `REMEDIATING: restarting techstream-app ... (ratio=['41.67'])` | remediator log |
| 12:35:41.45 | `RESTART COMPLETE: docker_status=204 restarts_performed=1` | remediator log |
| 12:35:49 | New `app_start_time_seconds`, `error_rate` back to 0.0 | timeline, `/healthz` |
| 12:36:01 | Injection phase ends, recovery traffic continues | `incident.json` |
| 12:36:21 | Rule returns to **inactive**, no active alerts in Alertmanager | timeline |
| 12:36:34.74 | Resolved notification received, correctly treated as a no-op | remediator log |
| 12:40:01 | Chaos run ends after the full recovery phase | `incident.json` |

Key intervals:

- **Alert to remediation started: 0.26 seconds.** `group_wait: 0s` doing its job.
- **Alert to restart complete: 6.9 seconds.**
- **Error ratio crossing 5 percent to restart complete: about 80 seconds**, almost
  all of it the deliberate `for: 1m` debounce.
- **Restart to alert resolved: 40 seconds.**

Confirmed independently by the chaos script, which samples the app's own process
start time throughout the run:

```json
"app_restart_count": 1,
"app_restarted_during_run": true
```

That is the app itself reporting it was restarted, not the remediator claiming it.

### The remediator log for the run

```
12:35:34,816 INFO    webhook received: group_status=firing alerts=1 firing=1
                     details=[{"alertname": "HighErrorRate", "app": "techstream-web",
                               "severity": "critical", "ratio": "41.67", ...}]
12:35:34,816 WARNING REMEDIATING: restarting techstream-app because HighErrorRate is firing (ratio=['41.67'])
12:35:41,455 WARNING RESTART COMPLETE: container=techstream-app docker_status=204 restarts_performed=1
12:36:34,742 INFO    webhook received: group_status=resolved alerts=1 firing=0
```

The `app` and `ratio` fields arriving populated confirms the alert labels and
annotations survive the whole path from rule to remediation.

## Webhook contract tests

Run before the loop, with direct POSTs. All six behaved correctly and **zero
restarts fired**, which is the point: the guards work.

| Case | Expected | Result |
|---|---|---|
| Wrong token, valid firing alert | 403 | 403 |
| No token at all | 403 | 403 |
| Valid token, resolved alert | 200 no-op | `{"remediated": false, "reason": "no firing alerts in payload"}` |
| Valid token, wrong alertname | 200 no-op | `{"remediated": false, "reason": "no HighErrorRate alert"}` |
| Batch says firing, alert itself resolved | 200 no-op | `{"remediated": false, "reason": "no firing alerts in payload"}` |
| Malformed JSON body | 400 | 400 |
| Restarts performed after all six | 0 | 0 |

The fifth case matters most. Alertmanager can send a batch whose top level
`status` reads `firing` while an individual alert inside it has already resolved.
Trusting the batch status would restart the app for an alert that had already
cleared.

## An important finding about how the alert resolves

The timeline shows this:

```
12:36:02   41.85    firing    HighErrorRate
12:36:08   nodata   firing    HighErrorRate
12:36:21   nodata   inactive  none
```

**The alert resolved because the numerator series disappeared, not because the
ratio computed below 5 percent.**

After the restart the app is a fresh process with counters at zero. With
`error_rate` back to 0 no 5xx ever occurs, so `http_requests_total{status=~"5.."}`
does not exist at all. `sum(rate(...))` over no series is empty, and empty divided
by anything is empty, so the whole expression returns nothing and the rule stops
firing.

The outcome is correct and the loop genuinely worked. But the mechanism is worth
knowing, because it has a consequence.

### The gap this exposes, and the fix

A completely dead app also produces no data. No requests means no series, means
the error ratio expression returns nothing, means `HighErrorRate` sits inactive
while the app is entirely down. The outage would page nobody.

Appending `or vector(0)` to the expression does not fix that. It makes a healthy
app read 0 percent instead of blank, which is nicer on the dashboard, but a dead
app still reads 0 percent and still looks fine.

The actual fix is a liveness alert, now added:

```yaml
- alert: AppDown
  expr: up{job="techstream-app"} == 0
  for: 2m
  labels:
    remediation: none
```

It is observation only on purpose. An app that is briefly unreachable during a
restart would otherwise trigger another restart, and a restart loop is worse than
the original fault. `for: 2m` is longer than any normal restart, so it only fires
on a genuine outage.

The error ratio expression itself is left exactly as specified, since the
dashboard and the alert are meant to evaluate the identical expression.

## How to verify it works

```bash
# 1. Rules are valid and loaded
docker compose exec -T prometheus promtool check rules /etc/prometheus/rules/alerts.yml
curl -s -X POST http://localhost:9090/-/reload
curl -s http://localhost:9090/api/v1/rules | python3 -m json.tool | grep -E '"name"|"state"'

# 2. Only HighErrorRate routes to remediation
docker compose exec -T alertmanager \
  amtool config routes test --config.file=/etc/alertmanager/alertmanager.yml alertname=HighErrorRate
docker compose exec -T alertmanager \
  amtool config routes test --config.file=/etc/alertmanager/alertmanager.yml alertname=HostCpuSaturation

# 3. Configure the webhook target, then start the local remediator
make configure URL='http://remediator:8000/'          # local
docker compose --profile local-remediation up -d --build remediator

# 4. Contract tests. Expect 403, then a no-op, and no restart.
TOKEN=$(grep '^REMEDIATION_WEBHOOK_TOKEN=' .env | cut -d= -f2)
docker compose exec -T app curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST -d '{}' 'http://remediator:8000/?token=wrong'
docker compose exec -T app curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"HostCpuSaturation"}}]}' \
  "http://remediator:8000/?token=$TOKEN"

# 5. The full loop. Watch it happen without touching anything.
./chaos/chaos.sh errors 120 --recovery 240 --rps 12
docker compose logs -f remediator     # in another terminal

# 6. Confirm the app reports its own restart
python3 -c "import json; d=json.load(open('chaos/incident.json')); print(d['app_restart_count'])"
```

For the deployed path, the equivalent evidence is in CloudWatch:

```bash
aws logs tail /aws/lambda/techstream-remediator --follow
aws ssm list-command-invocations --command-id <id from the log> --details
```

## One monitoring artifact to ignore

The timeline recorder printed `APP_START 0` at 12:35:42. That is the recorder's
`awk` returning nothing because the app was momentarily unreachable mid-restart,
not a real value. It incidentally confirms the restart happened.

## Next step

Step 6 adds `rca/rca.py`, which reads the incident window written by chaos.sh,
queries Prometheus across it, ranks the signals by which moved first and which
deviated most, and writes a JSON and Markdown report.
