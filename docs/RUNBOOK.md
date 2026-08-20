# Runbook: the TechStream self-healing loop

What happens, in order, when the app starts failing. Every timestamp below is
from a real run on 2026-08-17, not an illustration.

## The chain

```
chaos.sh sets the app error rate
  -> 5xx ratio crosses 5 percent
    -> Prometheus rule HighErrorRate goes pending, waits for: 1m
      -> rule fires
        -> Alertmanager routes it (only this alertname reaches remediation)
          -> webhook POST with a shared token
            -> Lambda validates, filters, calls SSM SendCommand    [on EC2]
            -> or the local remediator restarts via Docker API     [locally]
              -> app container restarts, in-memory chaos state clears
                -> error ratio falls, alert resolves
                  -> rca.py correlates the window
```

## Verified timeline

`./chaos/chaos.sh errors 120 --recovery 240 --rps 20`, no human intervention
after the script started.

| Time (UTC) | Event | Where to see it |
|---|---|---|
| 13:30:12 | Chaos run starts, error rate set to 0.4 | `chaos/incident.json` `started_at` |
| 13:30:42 | Error ratio crosses 5 percent, measured at 41.8 percent | Grafana Errors row |
| ~13:30:50 | Rule `HighErrorRate` goes **pending** | `make alerts` |
| 13:31:49.5 | Rule **fires**, ratio 37.44 percent | Prometheus alert `startsAt` |
| 13:31:49.5 | Alertmanager delivers the webhook, token accepted | `make remediator-logs` |
| 13:31:49.5 | `REMEDIATING: restarting techstream-app` | remediator log |
| 13:31:52.2 | `RESTART COMPLETE: docker_status=204` | remediator log |
| ~13:31:55 | `error_rate` back to 0.0, new process start time | `curl /healthz` |
| 13:32:12 | Last 5xx recorded. Errors cease. | RCA cessation evidence |
| 13:32:12 | Injection phase ends, recovery traffic continues | `incident.json` |
| ~13:32:40 | Rule returns to **inactive**, no active alerts | `make alerts` |
| 13:36:12 | Chaos run ends after the full recovery phase | `incident.json` |
| 13:37:45 | RCA report written | `rca/rca_report.md` |

### Intervals that matter

| Interval | Duration |
|---|---|
| Alert fires to remediation started | **0.0s**, same second |
| Alert fires to restart complete | **2.7s** |
| Error ratio crossing 5 percent to restart complete | **~70s** |
| Restart to errors ceasing | ~20s |
| First breach to alert resolved | ~110s |

Almost all the delay is the deliberate `for: 1m` debounce on the rule. Remediation
itself takes under 3 seconds. An earlier run measured 6.9 seconds for the same
step, so expect single digit seconds rather than a fixed number.

### Independent confirmation

The chaos script samples the app's own `app_start_time_seconds` throughout the
run and reports:

```json
"app_restart_count": 1,
"app_restarted_during_run": true
```

That is the app reporting it was restarted, not the remediator claiming it.

## Running the loop yourself

```bash
# One time
cp .env.example .env          # set GF_SECURITY_ADMIN_PASSWORD and REMEDIATION_WEBHOOK_TOKEN
make up

# Local path: start the stand-in and point Alertmanager at it
make remediator-up

# Watch it in two terminals
make remediator-logs
open http://localhost:3000/d/techstream-golden-signals

# Fire the loop
make chaos-errors

# Afterwards
make alerts
make rca
```

`make loop` does the whole thing including a 5 minute idle gap first, so the RCA
gets a clean baseline.

## What the RCA concluded

```
VERDICT: application_fault (confidence high)
Recommended remediation: restart
```

Error ratio breached first at 8.36x its threshold. No saturation signal breached
at any point, so the host had resources to spare while the application returned
errors. A restart is the correct response to a fault living in process state,
which is what the automation performed.

Run `make chaos-cpu DURATION=150 CPUS=4 RPS=30` and the verdict changes to
`resource_exhaustion` recommending `scale_out`, because CPU saturation leads and
a restart would not help.

## Deployed path: Lambda and SSM

On EC2 the webhook target is a Lambda Function URL instead of the local
remediator. Evidence lives in CloudWatch:

```bash
# The Lambda logs the SSM command ID
aws logs tail /aws/lambda/techstream-remediator --follow

# Confirm the command ran on the instance
aws ssm list-command-invocations --command-id <id-from-the-log> --details

# The instance must be a registered SSM managed instance, or nothing works
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}"
```

Configure it with:

```bash
TOKEN=$(grep '^REMEDIATION_WEBHOOK_TOKEN=' .env | cut -d= -f2)
make configure URL="$(terraform -chdir=infra/stack output -raw lambda_function_url)?token=$TOKEN"
```

## Note on the assignment mapping

The original brief reached the Lambda through a CloudWatch Alarm plus an
EventBridge rule. Alerting now lives in Prometheus, because Prometheus is what
sees application-level 5xx responses. CloudWatch never receives them.

The Alertmanager webhook therefore replaces the Alarm and EventBridge hop. Lambda
and SSM are unchanged, and remain the components doing the remediation.

If EventBridge is required, set `enable_eventbridge_audit = true`. The Lambda then
publishes a custom event **after** remediating, for audit only. It is deliberately
off the critical path: an audit bus being unavailable must never stop a restart.

## Scale-out alternative

Off by default, behind `enable_scale_out = true` and `asg_name`. The Lambda then
calls `autoscaling:SetDesiredCapacity` instead of restarting.

The tradeoff:

- **Restart** is right for a bad process. It clears the fault in seconds. This is
  the failure the lab injects, so it is the default.
- **Scale-out** is right for genuine saturation. It does nothing for a process
  returning 500s on every request, because the new instance runs the same broken
  code and you now have two of them.

Telling these apart is exactly what the RCA verdict is for. `application_fault`
recommends restart; `resource_exhaustion` recommends scale_out.

## When it does not work

| Symptom | Likely cause | Check |
|---|---|---|
| Alert fires, nothing restarts | Webhook URL not configured | `cat monitoring/alertmanager/webhook_url` |
| Remediator returns 403 | Token mismatch between `.env` and `webhook_url` | compare both |
| Alert never fires | Ratio never sustained above 5 percent for 1m | `make alerts`, Grafana Errors row |
| Ratio reads `nodata` | Traffic stopped, so the rate window is empty | raise `--recovery`, check the chaos script is still running |
| SSM command never runs | Instance not registered with SSM | `aws ssm describe-instance-information` |
| SSM runs but restart fails | Compose file not at `/opt/techstream` | SSM command output, `docker compose ps` |
| Restart storm | `repeat_interval` too short | `monitoring/alertmanager/alertmanager.yml` |
| Grafana panels empty | Datasource uid mismatch | `make status`, Grafana datasource health |
| RCA says no threshold crossings | Window and fault do not line up | check clocks, and that the run was long enough |
| RCA baseline worse than peak | Previous experiment still draining | leave 5 minutes idle, or use `make loop` |

### Two behaviours that look like bugs and are not

**A blank Errors panel on a healthy system.** The error ratio expression returns
empty, not zero, when no 5xx exists. Appending `or vector(0)` would show zero
instead. It is left as specified so the dashboard and the alert evaluate the
identical expression.

**The alert resolving from `nodata`.** After a restart the app is a fresh process
with zero counters, so the 5xx series stops existing and the expression returns
nothing. The outcome is correct, but note that a completely dead app produces the
same absence. That is why `AppDown` exists as a separate liveness alert, watching
`up{job="techstream-app"} == 0`.

## Teardown

```bash
# Local stack and volumes
make down

# AWS, main stack first
make tf-destroy
```

`infra/bootstrap` is destroyed **last**, because it holds the S3 bucket
containing the main stack's state. Destroying it first would strand that state.

The bucket also carries `prevent_destroy = true`, so teardown is deliberate:

```bash
# 1. Remove the lifecycle { prevent_destroy = true } block from
#    infra/bootstrap/main.tf
# 2. Then:
terraform -chdir=infra/bootstrap destroy
```

Emptying a versioned bucket needs all versions removed, which `terraform destroy`
will not do for you:

```bash
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
```
