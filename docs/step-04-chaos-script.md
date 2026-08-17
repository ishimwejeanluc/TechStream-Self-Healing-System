# Step 4: Chaos script

File: `chaos/chaos.sh`. Output: `chaos/incident.json`.

## What this step builds

A script that injects a realistic incident, records the window for the RCA to
read, and keeps traffic flowing afterwards so the self-healing loop can actually
be observed.

```bash
./chaos/chaos.sh errors 120                          # push error ratio above 5 percent
./chaos/chaos.sh cpu 90 --cpus 3                     # saturate cores with stress-ng
./chaos/chaos.sh errors 120 --rate 0.5 --rps 20      # tune the injection
./chaos/chaos.sh errors 60 --reset-on-exit           # traffic test, no remediation
```

| Option | Default | Purpose |
|---|---|---|
| `--rate` | 0.4 | Error rate for errors mode |
| `--cpus` | 2 | Cores to saturate in cpu mode |
| `--rps` | 12 | Requests per second to drive |
| `--recovery` | 240 | Seconds of traffic after injection ends |
| `--url` | `http://localhost:8080` | App base URL, also `APP_URL` |
| `--out` | `chaos/incident.json` | Incident file to write |
| `--reset-on-exit` | off | Clear the injected error rate when finishing |

## Two design decisions that shape the whole demo

### The error rate is not reset when injection ends

The injected rate lives in the app's memory, so only a container restart clears
it. That is deliberate.

If the script reset the rate at the end of injection, the error ratio would fall
because chaos stopped, not because remediation worked. The runbook would show a
recovering graph that proves nothing, and there would be no way to tell a working
self-healing loop from a broken one.

Leaving it set means exactly one thing can bring the error ratio down: something
restarting the app. `--reset-on-exit` exists for when you only want a traffic
test with no remediation involved.

### Traffic keeps flowing after injection ends

The alert expression is a rate over a one minute window. If traffic stopped when
injection ended, that rate would fall to zero, the expression would return no
data, and the alert would resolve because traffic vanished rather than because
the app recovered.

This was not theoretical. An early test run used a 75 second recovery, and the
error ratio went to `no-data` 30 seconds after the restart:

```
+10s after restart: error_ratio=37.8%
+20s after restart: error_ratio=32.74%
+30s after restart: error_ratio=no-data
+40s after restart: error_ratio=no-data
```

The ratio never got the chance to fall below 5 percent on its own. The default
recovery is now 240 seconds, sized from the real loop timing:

| Stage | Time |
|---|---|
| Ratio crosses 5 percent, rule waits `for: 1m` | 60s |
| Alertmanager plus Lambda plus SSM delivery | 10 to 30s |
| Container restart | 10 to 20s |
| 1 minute rate window drains so the ratio reads below threshold | 60s |
| Alertmanager sends the resolved notification | up to 60s |
| **Total** | **about 210s** |

Do not shorten `--recovery` below about 180 for a full loop run.

## incident.json

Written on exit, including on Ctrl-C, so an aborted run still leaves the RCA
something to read.

```json
{
  "mode": "errors",
  "target": "http://localhost:8080",
  "note": "Lab-generated load from chaos.sh. These are simulated requests, not real user traffic.",
  "parameters": {
    "error_rate": 0.4, "cpus": null, "requested_rps": 12,
    "injection_seconds": 60, "recovery_seconds": 60, "reset_on_exit": false
  },
  "started_at": "2026-08-14T15:50:39Z",
  "injection_ended_at": "2026-08-14T15:51:39Z",
  "ended_at": "2026-08-14T15:52:39Z",
  "duration_seconds": 120,
  "windows": {
    "baseline":  { "start_epoch": 1786722339, "end_epoch": 1786722639 },
    "injection": { "start_epoch": 1786722639, "end_epoch": 1786722699 },
    "recovery":  { "start_epoch": 1786722699, "end_epoch": 1786722759 },
    "query":     { "start_epoch": 1786722339, "end_epoch": 1786722819 }
  },
  "requests": { "sent": 1344, "http_2xx": 774, "http_5xx": 570, "observed_rps": 11 },
  "app_start_time_seconds_first": 1786722172.48,
  "app_start_time_seconds_last": 1786722172.48,
  "distinct_app_processes_seen": 1,
  "app_restart_count": 0,
  "app_restarted_during_run": false
}
```

Three parts of this are worth explaining.

**Four windows, not one.** The RCA needs a quiet baseline before injection to
know what normal looks like, so `query` is padded 300 seconds before the start
and 60 seconds after the end. Separating `injection` from `recovery` lets the RCA
distinguish "the signal was bad" from "the signal came back".

**The note field.** Every downstream report inherits it. These are simulated
requests, and the RCA has to say so rather than implying real users were
affected.

**Restart detection.** `app_start_time_seconds` comes from the app's own metrics
and steps up whenever the process restarts. Counting distinct values across the
run gives `app_restart_count`, which is direct app-level evidence of whether
remediation fired. In the sample above it is 0, correctly, because the
remediation Lambda is not wired up until Step 5.

## How to verify it works

```bash
# Argument validation
./chaos/chaos.sh --help
./chaos/chaos.sh bogus 60          # rejects the mode
./chaos/chaos.sh errors abc        # rejects the duration
./chaos/chaos.sh errors 60 --rps x # rejects the option value

# Errors mode. Watch the ratio cross 5 percent.
./chaos/chaos.sh errors 60 --recovery 60 --rps 12 &
curl -s --data-urlencode 'query=100 * sum(rate(http_requests_total{status=~"5.."}[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 1)' \
  http://localhost:9090/api/v1/query

# CPU mode. Expect stress-ng running and container CPU above 190 percent.
./chaos/chaos.sh cpu 30 --cpus 2 --rps 6 --recovery 20 &
docker top techstream-app -eo pid,comm | grep stress-ng
docker stats --no-stream --format '{{.CPUPerc}}' techstream-app

# The incident file is valid JSON
python3 -c "import json; print(json.load(open('chaos/incident.json'))['mode'])"
```

## Verification results

| Check | Result |
|---|---|
| Parses under bash 3.2 | yes, `bash -n` clean |
| No args | prints usage, exit 2 |
| Bad mode | `error: mode must be 'errors' or 'cpu', got 'bogus'` |
| Bad duration | `error: duration must be a positive integer number of seconds` |
| Bad option value | `error: --rps must be a non-negative integer, got 'xyz'` |
| Unknown flag | `error: unknown option '--nope'` |
| App unreachable | clear message plus the command to start the stack |
| Errors mode ratio | crossed 5 percent within about 20s, held at 41 to 46 percent |
| Errors mode accuracy | 570 of 1344 requests were 5xx, 42.4 percent against 0.4 injected |
| Traffic rate | 11 observed against 12 requested |
| CPU mode | `stress-ng` plus workers running, container CPU 197 percent |
| CPU mode latency | 55ms under load against about 27ms idle |
| CPU mode errors | 0 of 222 requests failed, correct since cpu mode injects no errors |
| Restart detection | `distinct_app_processes_seen: 2`, `app_restart_count: 1` |
| Zero traffic edge case | `--rps 0` still produces valid JSON with all counts 0 |
| incident.json | valid JSON in every mode tested |

## Three bugs found and fixed during verification

### 1. bash 4 syntax on a bash 3.2 machine

The option validation used `${n,,}` to lowercase a variable name. That is a bash
4 feature, and macOS ships bash 3.2, so it was a syntax error locally while
working fine on the Ubuntu instance. That split is the worst kind of bug, so it
now uses `tr` instead.

### 2. Restart detection missed the restart it was built to catch

The first version sampled `app_start_time_seconds` exactly twice, at start and at
exit. A test restart landed 3 seconds before the run ended, and the JSON came
back with identical before and after values and `app_restarted_during_run: false`
even though the restart had definitely happened. The final sample raced the
restart and read the old process.

Two point comparison also misses a restart entirely if the app restarts and the
run continues past it. The script now samples every fifth batch, roughly every 5
seconds, and counts distinct process start times across the whole run. Retested
by restarting the container the moment the ratio crossed 5 percent, which is what
the alert will do:

```
distinct_app_processes_seen: 2
app_restart_count: 1
app_restarted_during_run: true
```

`/metrics` is excluded from the app's own request counters, so this extra polling
does not pollute the error ratio.

### 3. grep -c produced invalid JSON on a clean run

This one only appeared on the happy path. The counting helper was:

```bash
grep -cE "${pattern}" "${STATUS_LOG}" 2>/dev/null || echo 0
```

`grep -c` prints `0` **and** exits 1 when nothing matches, so `|| echo 0` emitted
a second zero. The result was `0\n0`, which landed in the file as:

```json
    "http_5xx": 0
0,
```

Invalid JSON. Errors mode never hit it because both 2xx and 5xx were always
present. CPU mode injects no errors, so its 5xx count was zero and every cpu-mode
run wrote a corrupt incident file.

The fix assigns first and handles the exit status separately, which keeps it to a
single value:

```bash
n="$(grep -cE "${pattern}" "${STATUS_LOG}" 2>/dev/null)" || n=0
```

The same pattern was present in the distinct process count and was fixed too.
Verified with `--rps 0`, where every count is zero, which is the strongest test
of it.

### Also hardened: atomic writes

While chasing bug 3, a test that piped the script through `head -20` killed it
with SIGPIPE part way through writing the file. A plain `cat > incident.json`
truncates the target immediately, so a failure mid-write destroys the previous
incident record and leaves invalid JSON. It now writes to a temp file and moves
it into place, so the previous record survives any failed run.

## Next step

Step 5 adds the `HighErrorRate` alert rule, routes it through Alertmanager to the
Lambda Function URL, and confirms the restart happens without anyone touching the
box. That is the run whose timestamps go in the runbook, and it is the run where
`app_restart_count` should finally read 1 on its own.
