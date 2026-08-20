# Step 2: Web app

Directory: `app/`

## What this step builds

A small Flask app that does three jobs:

1. Serves normal traffic with realistic latency, so the Golden Signals have
   something to measure
2. Exposes Prometheus metrics under the exact names the dashboard and the alert
   rule depend on
3. Provides two chaos endpoints that inject the incident the self-healing loop
   reacts to

Files: `app.py`, `requirements.txt`, `Dockerfile`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Normal traffic, subject to the injected error rate |
| GET | `/work` | Normal traffic, subject to the injected error rate |
| GET | `/healthz` | Health check, never fails on purpose |
| GET | `/metrics` | Prometheus scrape target |
| POST | `/chaos/errors?rate=0.4` | Set the share of requests that return 500 |
| POST | `/chaos/cpu?seconds=45&cpus=2` | Saturate cores with stress-ng in the background |

## Metrics contract

These names are fixed. The dashboard panels and the `HighErrorRate` alert both
read them, so renaming either one breaks Step 3 and Step 5.

```
http_requests_total{method,endpoint,status}    counter, status is the numeric code
http_request_duration_seconds                 histogram, produces _bucket{le=...}
```

The histogram is what gives the percentile panels their `le` label:

```
http_request_duration_seconds_bucket{endpoint="/",le="0.025",method="GET"} 7.0
```

Buckets are spread around the expected p50 of about 25ms and out past a second,
so p50, p95 and p99 stay distinguishable as latency degrades:

```python
buckets=(0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0)
```

The `endpoint` label uses the Flask route template rather than the raw path:

```python
return request.url_rule.rule if request.url_rule else "unmatched"
```

Using the raw path would give unbounded label cardinality the moment anything
requests a URL with an ID or a query in it.

Three extra gauges are exposed for visibility. Nothing depends on them:

```
chaos_error_rate                 current injected error share
chaos_cpu_runs_active            stress-ng invocations running
chaos_cpu_cores_requested        cores those invocations are saturating
app_start_time_seconds           process start time, steps up on restart
```

`app_start_time_seconds` is useful in the runbook. It is the app-level proof
that the SSM restart actually replaced the process.

## Two design decisions worth explaining

### /metrics and /healthz are excluded from request metrics

```python
UNMEASURED_ENDPOINTS = {"/metrics", "/healthz"}
```

Prometheus scrapes `/metrics` every 15 seconds and the container health check
polls `/healthz` continuously. Both are infrastructure traffic, not application
traffic.

Counting them would pad the denominator of the error ratio. With enough health
and scrape traffic in the mix, a genuine failure rate of 8 percent could be
diluted below the 5 percent alert threshold, and the threshold would end up
depending on scrape interval rather than on real failures. Excluding them keeps
the error ratio a statement about application requests.

### /healthz never lies

`/healthz` is deliberately not subject to the injected error rate.

If the health check failed during chaos, Docker would mark the container
unhealthy and restart it on its own. The alert would resolve, the error rate
would drop, and there would be no way to tell whether the SSM remediation path
did the work or whether Docker just beat it to the punch. Keeping `/healthz`
honest means the only thing that restarts the container is the remediation we
are testing.

## Why the request does real CPU work

```python
def _do_work() -> None:
    total = 0
    for i in range(CPU_WORK_ITERATIONS):   # about 10ms of CPU
        total += i * i

    seconds = (BASE_LATENCY_MS / 1000.0) * random.lognormvariate(0.0, 0.45)
    time.sleep(min(seconds, 2.0))          # about 15ms, adds spread
```

Two parts, each with a purpose. The busy loop burns real CPU, so when stress-ng
saturates the cores requests genuinely slow down. The sleep adds a lognormal
spread so p50, p95 and p99 stay distinguishable instead of collapsing onto one
line.

The CPU part has to be the larger of the two. If latency were sleep dominated,
CPU saturation would barely affect it, and the RCA in Step 6 could never observe
CPU leading latency. The causal chain it reports has to actually exist.

### This was originally sized wrong

The first version used `CPU_WORK_ITERATIONS = 1500` with a 25ms sleep, and this
document claimed a measured 27ms idle versus 58ms under load. That 2.2x was real
but far weaker than it needed to be, and the reason only became clear in Step 6.

Benchmarked in the actual image:

```
   1500 iterations ->   0.70 ms of CPU
  25000 iterations ->  10.3  ms of CPU
```

1500 iterations was **0.7ms**. The request was almost entirely `sleep`, and a
sleep takes its wall clock time no matter how contended the CPU is. Pushed to
four times core oversubscription, 16 stress workers on 4 cores at 589 percent
container CPU, p95 latency still only reached 0.185s. CPU saturation was
producing essentially no latency signal.

Now `CPU_WORK_ITERATIONS = 25000` (about 10ms of CPU) with `BASE_LATENCY_MS = 15`,
so baseline latency stays in the same range while the CPU-bound share dominates.

Measured after the change:

| Condition | p50 | p95 |
|---|---|---|
| Idle | about 0.03s | about 0.07s |
| Cores saturated, 30 req/s | 0.099s | 0.248s |
| Cores saturated, sustained | - | up to 0.939s |

p95 now moves by more than 3x under CPU pressure, which is enough for the RCA to
see CPU and latency as a connected pair rather than two unrelated signals.

## Why gunicorn runs a single worker

```
gunicorn --workers 1 --worker-class gthread --threads 16
```

Chaos state is one in-memory float guarded by a lock. With multiple workers,
each process would hold its own copy, so `POST /chaos/errors?rate=0.4` would set
the rate in one worker and requests landing on the others would stay healthy.
The observed error rate would be a fraction of what was asked for.

Single worker also avoids `prometheus_client` multiprocess mode, which needs a
shared directory and changes how histograms aggregate. Threads carry the request
concurrency the lab generates, and stress-ng runs as a separate child process so
it is not affected by the GIL.

## In-memory state is the point

Chaos state is deliberately not persisted. Restarting the container clears it,
which is exactly what makes the automated remediation observable end to end:

```
error_rate 0.4  ->  container restart  ->  error_rate 0.0  ->  alert resolves
```

Verified below.

## Dockerfile

`python:3.12-slim` plus two apt packages:

- `stress-ng` drives the CPU chaos mode
- `curl` is used by the container health check in Step 3

`procps` is deliberately not installed. Inspecting stress-ng from inside the
container is not needed, because `docker top` does it from the host.

## How to verify it works

```bash
cd app
docker build -t techstream-app:test .
docker run -d --name ts-app-test -p 18080:8080 techstream-app:test

# 1. Health
curl -s http://localhost:18080/healthz

# 2. Normal traffic returns 200
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://localhost:18080/; done

# 3. The metric names the dashboard needs, with the le label on the histogram
curl -s http://localhost:18080/metrics | grep -E '^http_requests_total|_bucket'

# 4. Error injection. Expect all 500 at rate=1.0
curl -s -X POST 'http://localhost:18080/chaos/errors?rate=1.0'
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://localhost:18080/; done

# 5. CPU chaos. Expect stress-ng processes and CPU above 200 percent
curl -s -X POST 'http://localhost:18080/chaos/cpu?seconds=30&cpus=2'
docker top ts-app-test -eo pid,comm | grep stress
docker stats --no-stream --format 'CPU={{.CPUPerc}}' ts-app-test

# 6. Restart clears chaos state, which is what SSM remediation relies on
curl -s -X POST 'http://localhost:18080/chaos/errors?rate=0.4' >/dev/null
docker restart ts-app-test
curl -s http://localhost:18080/healthz    # error_rate back to 0.0

docker rm -f ts-app-test
```

Note `docker top` needs the PID field, so use `-eo pid,comm`. Passing `-eo comm`
alone fails with "Couldn't find PID field in ps output".

## Verification results

Every check below was run against the built image.

| Check | Result |
|---|---|
| Image builds | Success |
| stress-ng present | version 0.19.02 |
| `/healthz` | 200 with state fields |
| 20 requests to `/` and `/work` | all 200 |
| Metric names and `le` label | correct, 28 bucket series |
| `status` label holds numeric code | `status="200"`, `status="500"` |
| `rate=1.0` | 10 of 10 returned 500 |
| `rate=0.4` | 13 of 40 returned 500, within one standard deviation of 16 |
| `rate=abc` | rejected with 400 |
| `/healthz` and `/metrics` in counters | 0 series, correctly excluded |
| CPU chaos | parent `stress-ng` plus 2 `stress-ng-cpu` workers, 213 to 217 percent CPU |
| Latency under CPU load | 58ms versus 27ms idle |
| Gauge reaping | `chaos_cpu_runs_active` returns to 0 after stress-ng exits |
| Concurrent runs | 1 run/2 cores, then 2 runs/3 cores, aggregated correctly |
| Restart clears state | `error_rate` 0.4 to 0.0, `cpu_runs` 1 to 0 |
| `python3 -m py_compile` | clean |

## One bug found and fixed during verification

The CPU gauge was originally named `chaos_cpu_workers_active` but counted
stress-ng **invocations**, not worker processes. Burning 2 cores reported `1.0`,
which reads as one core.

Split into two accurately named gauges:

```
chaos_cpu_runs_active        1.0    one POST /chaos/cpu still running
chaos_cpu_cores_requested    2.0    saturating two cores
```

Confirmed with two concurrent runs: `runs=2`, `cores=3`.

## Next step

Step 3 puts this app behind Prometheus, Grafana, node_exporter and cAdvisor in
Docker Compose, and confirms the scrape targets come up.
