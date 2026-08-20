# TechStream lab: complete guide, zero to finished

Everything in order, with the traps that cost time the first time round.

Run every command from the repo root unless told otherwise.

## What you are building

```
app serves traffic ──> Prometheus scrapes ──> Grafana dashboard
                            │
                            ├──> alert rule fires ──> Alertmanager ──> Lambda ──> SSM
                            │                                                      │
                            │                                          restarts the app
                            │
                            └──> remote_write ──> Grafana Cloud ──> ML jobs + Sift
```

Two remediation paths, and one is a stand-in:

| Path | Used for | Trigger |
|---|---|---|
| Local remediator | Verifying the loop on your laptop | Docker API restart |
| Lambda plus SSM | The real deployed path on EC2 | `ssm:SendCommand` |

## Part 0: prerequisites

| Need | Why | Check |
|---|---|---|
| Docker | Runs the whole stack | `docker info` |
| Terraform >= 1.10 | S3-native state locking | `terraform version` |
| AWS CLI, credentials | EC2, Lambda, SSM, S3 | `aws sts get-caller-identity` |
| Python 3 | `rca.py`, and the Makefile helpers | `python3 -V` |
| Grafana Cloud account | ML jobs and Sift | free signup |

On a Mac, `bash` is 3.2. Every script here is written for it.

## Part 1: run it locally

Nothing in this part costs money or touches AWS.

```bash
cp .env.example .env
```

Edit `.env` and set two values:

```bash
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 24)   # paste the result
REMEDIATION_WEBHOOK_TOKEN=$(openssl rand -hex 32)       # paste the result
```

Grafana refuses to start if the password is empty. That is deliberate, not a bug.

```bash
make up
```

Builds the app, starts six containers, waits until the app and Prometheus answer.

### Verify before moving on

```bash
make status
```

All five scrape targets must read `up`. If cAdvisor is `down` for the first
20 seconds that is normal, it is still starting.

Then open the dashboard:

```
http://localhost:3000/d/techstream-golden-signals
```

Panels will be empty until traffic flows. That is expected, not broken.

```bash
make traffic DURATION=60 RPS=20
```

Now the Latency, Traffic and Saturation rows fill in. The Errors row stays blank
until the first 5xx, because the error ratio expression returns empty rather than
zero when no errors exist.

## Part 2: the self-healing loop, locally

```bash
make remediator-up
```

Starts the local stand-in and points Alertmanager at it. It mounts the Docker
socket, which is root equivalent on your machine, so it sits behind a compose
profile and never starts with a plain `docker compose up`. Never run it on EC2.

Watch it in a second terminal:

```bash
make remediator-logs
```

Then break the app:

```bash
make chaos-errors
```

What you should see, and roughly when:

| Time from start | Event |
|---|---|
| ~20s | Error ratio crosses 5 percent |
| ~30s | Rule goes `pending` |
| ~90s | Rule `firing`, webhook delivered, restart happens |
| ~2s later | `RESTART COMPLETE: docker_status=204` |
| ~40s later | Rule back to `inactive` |

Check it with `make alerts` while it runs.

The restart is what fixes it. The injected error rate lives only in the app's
memory, so a fresh process starts clean. `chaos.sh` deliberately does not reset
it, otherwise you could not tell remediation from the chaos simply ending.

### The offline RCA

```bash
make rca
less rca/rca_report.md
```

Expect `application_fault` with `restart` recommended. Run
`make chaos-cpu DURATION=150 CPUS=4 RPS=30` instead and the verdict changes to
`resource_exhaustion` recommending `scale_out`.

Leave 5 minutes idle before an RCA run, or the baseline window overlaps the
previous experiment and every "times normal" figure is wrong. `make loop` handles
that wait for you.

## Part 3: ship metrics to Grafana Cloud

### Token 1, for remote_write

In the **Cloud Portal** at grafana.com, not inside Grafana:

1. Your org, then **Access Policies**
2. **Create access policy**, realm your stack, scope **`metrics:write`**
3. **Add token**, copy it once

Get the endpoint and username from **your stack, Prometheus, Send Metrics**. The
username is a numeric instance ID.

```bash
make cloud-token TOKEN=glc_...
make cloud-status
```

`make cloud-token` overwrites the whole file. Hand-editing
`monitoring/prometheus/grafana_cloud_token` is where it goes wrong: the file must
contain the token and nothing else, no placeholder line above it, no quotes.

### Verify

`make cloud-status` should show `samples_failed_total` at 0 and a non-zero send
rate. **Active Series** in the portal climbs off 0 within a minute or two,
settling near 121 because an allowlist ships only what the ML jobs and dashboard
actually query, out of about 3600 local series.

If you see `401 authentication error: invalid token`, the file has extra content
or the token is wrong.

## Part 4: AWS infrastructure

Now it costs money. A `t3.medium` is roughly $0.05 per hour.

### One time: the state backend

The main config keeps state in S3, but that bucket has to be created by Terraform
too. `infra/bootstrap` breaks the cycle with local state.

```bash
make tf-bootstrap
```

7 resources: the bucket, versioning, encryption, public access block, ownership
controls, a TLS-only policy, and a lifecycle rule.

### The main stack

```bash
cd infra/stack
cp terraform.tfvars.example terraform.tfvars
```

Set two values in `terraform.tfvars`:

```hcl
allowed_cidr              = "1.2.3.4/32"    # curl -s https://checkip.amazonaws.com
remediation_webhook_token = "..."           # SAME value as in .env
```

**If you skip this file, Terraform prompts for `allowed_cidr` on the command line
and a stray "yes" becomes the value**, which fails validation with a confusing
error. Create the file first.

`allowed_cidr` is the firewall. It controls who can reach ports 22, 3000, 8080,
9090 and 9093. Ports 9090 and 9093 have **no authentication at all**, and anyone
reaching 9093 can post an alert that triggers a restart. A `/32` of your own IP is
the safe setting. `0.0.0.0/0` works and is convenient for a lab, because a home IP
changes and a stale value locks you out, but understand what you are opening.

```bash
make tf-plan     # expect 17 to add
make tf-apply
make tf-output
```

### Deploy the app to the instance

```bash
IP=$(terraform -chdir=infra/stack output -raw instance_public_ip)
rsync -av --exclude '.git' --exclude '.terraform' ./ ubuntu@$IP:/opt/techstream/

ssh ubuntu@$IP
cd /opt/techstream
cp .env.example .env      # set the password and token again
make up
```

The path matters. The SSM document runs `cd /opt/techstream && docker compose
restart app`, so the compose file has to be exactly there.

### Point Alertmanager at the real Lambda

On the instance:

```bash
TOKEN=$(grep '^REMEDIATION_WEBHOOK_TOKEN=' .env | cut -d= -f2)
make configure URL="<lambda_function_url>?token=$TOKEN"
```

Do **not** run `make remediator-up` here. That is the local stand-in and it needs
the Docker socket. The Lambda plus a scoped IAM policy does the same job without
that exposure.

Then verify the AWS path:

```bash
aws ssm describe-instance-information     # the instance must be listed
aws logs tail /aws/lambda/techstream-remediator --follow
make chaos-errors
```

The Lambda logs an SSM command ID. Confirm it ran:

```bash
aws ssm list-command-invocations --command-id <id> --details
```

## Part 5: Grafana Cloud ML

### Token 2, for Terraform

A different credential from a different place. Inside your Grafana instance:

1. **Administration**, **Users and access**, **Service accounts**
2. **Add service account**, name it `terraform-techstream-ml`, role **Admin**
3. **Add service account token**, copy it once

It starts with `glsa_`. A `glc_` token is a Cloud Portal token and cannot create
ML jobs. Terraform rejects the wrong type at plan time.

```bash
cd infra/grafana-ml
cp terraform.tfvars.example terraform.tfvars
# set grafana_auth = "glsa_..."
```

```bash
make ml-plan
make ml-apply
make ml-output
```

This creates a forecast on the error ratio, a DBSCAN outlier detector on
per-container CPU, and two insight alerts. Its state lives in the same bucket
under a different key, so it is independent of the AWS stack.

The ML alerts carry `remediation = "none"` and are routed nowhere. A mistrained
model cannot restart your app.

### Train before you break

This is the step people skip.

```bash
make ml-baseline      # 10 minutes of healthy traffic
```

A model learns normal from the data it has. If chaos runs inside the training
window, it learns that a 40 percent error rate is normal and will never flag it.

For a convincing demo, leave the stack shipping **overnight** so the model sees a
real daily cycle. Ten minutes produces a crude model.

Check the jobs are trained and healthy at:

```
https://<your-stack>.grafana.net/a/grafana-ml-app/
```

### Produce the Sift artifact

```bash
make chaos-errors
make chaos-cpu DURATION=150 CPUS=4 RPS=30
```

Then in Grafana, run a **Sift** investigation over the incident window and export
its findings. That export is the AI/ML root cause deliverable. `rca.py` remains
as the offline fallback and as a comparison.

## Part 6: teardown, order matters

```bash
make down          # local containers and volumes
make ml-destroy    # Grafana ML jobs only
make tf-destroy    # AWS stack: EC2, Lambda, SG, IAM
```

Then delete the `terraform-techstream-ml` service account in Grafana, which
revokes its token, and revoke the `glc_` token in the Cloud Portal.

**The bootstrap bucket is destroyed last**, because it holds the state for both
Terraform configs above. It also carries `prevent_destroy`, so it takes a
deliberate edit:

1. Delete the `lifecycle { prevent_destroy = true }` block in
   `infra/bootstrap/main.tf`
2. Empty the bucket. A versioned bucket needs every version removed, which
   `terraform destroy` will not do:

```bash
BUCKET=techstream-tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-west-1
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
```

3. `terraform -chdir=infra/bootstrap destroy`

Leaving the EC2 instance running is the expensive mistake. Nothing else here
costs meaningfully.

## Traps, and what they look like

| Symptom | Cause | Fix |
|---|---|---|
| Grafana will not start | `GF_SECURITY_ADMIN_PASSWORD` empty | set it in `.env` |
| Dashboard panels all error | datasource uid mismatch | the provisioned uid is `techstream-prometheus` |
| Errors row blank on a healthy app | the ratio returns empty, not zero | expected, not a fault |
| `401 invalid token` on remote_write | token file has extra lines or quotes | token only, one line |
| `http_requests_total` missing in the cloud | the app served no requests since restart, so the counter does not exist yet | send traffic |
| Terraform prompts for a value | `terraform.tfvars` missing | create it before plan |
| `allowed_cidr is "yes"` | typed into that prompt | as above |
| `Error acquiring the state lock` with your own name | a previous run was killed before releasing | `terraform force-unlock <ID>` |
| Locked out of the UIs | your public IP changed | update `allowed_cidr`, re-apply |
| SSM command runs but nothing restarts | compose file not at `/opt/techstream` | check the rsync target |
| Anomaly score never moves | model trained during chaos, or too little history | retrain on clean data |
| RCA baseline worse than peak | previous experiment still draining | leave 5 minutes idle, or `make loop` |

`make validate` checks Terraform formatting and validity, the Prometheus config
and rules, the Alertmanager config, the compose file, every Python file and
`chaos.sh` in one go.

## Where the detail lives

| Document | Contents |
|---|---|
| `docs/step-00` to `step-06` | one per build step, with what went wrong |
| `docs/RUNBOOK.md` | the loop with real timestamps, troubleshooting, teardown |
| `docs/grafana-ml-setup.md` | the Grafana Cloud ML path in depth |
| `README.md` | overview and architecture |
