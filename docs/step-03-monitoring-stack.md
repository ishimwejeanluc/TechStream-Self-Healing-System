# Step 3: Monitoring stack

Files: `docker-compose.yml` and `.env.example` at the repo root, config under
`monitoring/`.

## What this step builds

Six services in Docker Compose, Prometheus scraping all of them, and a Golden
Signals dashboard that Grafana provisions from a committed JSON file rather than
one clicked together in the UI.

```
.
├── docker-compose.yml         composes the whole system, app plus monitoring
├── .env.example               Grafana password and app tuning
├── app/                       built by the app service
└── monitoring/
    ├── prometheus/prometheus.yml
    ├── alertmanager/alertmanager.yml
    └── grafana/
        ├── provisioning/
        │   ├── datasources/prometheus.yml
        │   └── dashboards/dashboards.yml
        └── dashboards/golden-signals.json
```

`docker-compose.yml` sits at the repo root because it spans both `app/` and
`monitoring/`, so neither directory owns it. Every compose command runs from the
repo root, and compose reads `.env` from there automatically.

### Knock-on change to the SSM document

Moving compose to the root changed where the remediation command has to run. The
SSM document in `infra/modules/remediation/ssm.tf` was updated from

```
cd /opt/techstream/monitoring && docker compose restart app
```

to

```
cd /opt/techstream && docker compose restart app
```

If these two ever disagree, remediation fails with "no configuration file
provided" and the alert never resolves. Worth checking together.

## Pinned versions

No `:latest` anywhere. A rebuild months from now produces the same stack.

| Service | Image |
|---|---|
| app | `techstream-app:1.0.0` (built from `./app`) |
| prometheus | `prom/prometheus:v2.54.1` |
| alertmanager | `prom/alertmanager:v0.27.0` |
| grafana | `grafana/grafana:11.2.2` |
| node-exporter | `prom/node-exporter:v1.8.2` |
| cadvisor | `gcr.io/cadvisor/cadvisor:v0.49.1` |

## Scrape targets

| Job | Target | Provides |
|---|---|---|
| techstream-app | `app:8080` | `http_requests_total`, `http_request_duration_seconds` |
| node-exporter | `node-exporter:9100` | `node_cpu_seconds_total`, `node_memory_*` |
| cadvisor | `cadvisor:8080` | `container_cpu_usage_seconds_total` with the `name` label |
| prometheus | `localhost:9090` | self-monitoring |
| alertmanager | `alertmanager:9093` | alerting pipeline health |

No relabelling on any of these jobs. The dashboard reads the metric names
directly, so renaming or dropping labels would blank out panels.

## The dashboard

Five rows, 12 panels, 14 queries.

### Which dashboard was chosen

Two candidates existed: one written for this step, and one supplied separately.
The supplied version was better on most counts and was adopted as the base.

| Aspect | Supplied version | Earlier version |
|---|---|---|
| At-a-glance stat row | Yes, 4 KPIs | Missing |
| Datasource | `${datasource}` variable, portable | Hardcoded uid |
| Legends | Table mode with mean, max, last | Plain list |
| 5 percent threshold | `line+area`, more visible | `line` only |
| 5xx colour override | `byRegexp "5.*"`, catches 502 and 503 | `byName "500"` only |
| Field config | Complete Grafana 11 export shape | Minimal |
| Container CPU | Cores with `unit: none`, honest | Multiplied by 100, called percent |

Two things were fixed before adopting it.

**The datasource variable had no default.** `"current": {}` means nothing is
selected at provision time. Grafana usually falls back to the default
datasource, but relying on that is a common reason a provisioned dashboard opens
with every panel erroring. It now carries an explicit default:

```json
"current": {
  "selected": false,
  "text": "Prometheus",
  "value": "techstream-prometheus"
}
```

The variable is kept rather than replaced with a hardcoded uid, because it keeps
the dashboard portable to another Grafana with a differently named Prometheus.

**The latency rate windows were split by purpose.** The supplied version used
`[5m]` for latency while errors and traffic used `[1m]`. Both windows have a real
downside, measured on the live stack:

```
traffic flowing:  p95[1m] = 0.0693   p95[5m] = 0.0663
traffic idle:     p95[1m] = nan      p95[5m] = 0.0663
```

`[1m]` returns NaN when no requests fall inside the window, because every bucket
rate is zero and `histogram_quantile` is undefined on that. `[5m]` stays
populated but smears the onset of a latency rise across five minutes.

The split now reflects what each panel is for:

- **p95 stat KPI** keeps `[5m]`. It is a single always-on number, and NaN
  flicker on an idle system would be worse than a little smoothing.
- **Percentile timeseries** uses `[1m]`. It has to show the shape of the
  incident, and a five minute window flattens exactly the
  CPU then latency then errors ordering the Step 6 RCA has to detect. It also
  matches the `[1m]` window the alert rule evaluates.

### Golden Signals at a glance

Four stat panels: error rate with thresholds at 3 and 5 percent on a solid
background, p95 latency, total traffic, and host CPU busy.

### Latency

```promql
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[1m])) by (le))
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le))
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[1m])) by (le))
```

### Traffic

```promql
sum(rate(http_requests_total[1m])) by (status)
sum(rate(http_requests_total[1m]))
```

The by-status panel is stacked, with a `byRegexp "5.*"` override pinning every
5xx series to red so a rising error share is visible without reading the legend.

### Errors

```promql
100 * sum(rate(http_requests_total{status=~"5.."}[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 1)
sum(rate(http_requests_total{status=~"5.."}[1m]))
```

The first is the exact expression the `HighErrorRate` alert evaluates in Step 5,
which matters: the line you watch and the line that pages you are the same
computation.

The 5 percent threshold is drawn as a line with shading above it:

```json
"custom": { "thresholdsStyle": { "mode": "line+area" } },
"thresholds": {
  "mode": "absolute",
  "steps": [
    { "color": "green", "value": null },
    { "color": "red", "value": 5 }
  ]
}
```

### Saturation

```promql
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)
sum(rate(container_cpu_usage_seconds_total{name!=""}[1m])) by (name)
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

Container CPU is reported in fractions of a core with `unit: none`, so a value of
2 means two full cores. That is more honest than multiplying by 100 and labelling
it percent, since a container can exceed one core.

## Provisioning details that matter

### The datasource needs a fixed uid

```yaml
datasources:
  - name: Prometheus
    uid: techstream-prometheus
```

Without an explicit `uid`, Grafana assigns a random one and the dashboard's
`${datasource}` default has nothing valid to point at.

### The dashboard is read only in the UI

```yaml
allowUiUpdates: false
updateIntervalSeconds: 30
```

Edits have to go into the committed JSON, which keeps the repo the source of
truth. Grafana rereads the file every 30 seconds, so changing it shows up
without a restart.

### Grafana refuses to start without a password

```yaml
GF_SECURITY_ADMIN_PASSWORD: ${GF_SECURITY_ADMIN_PASSWORD:?set GF_SECURITY_ADMIN_PASSWORD in .env}
```

The `:?` form fails the whole `docker compose up` with a message naming the file
to fix. The alternative, defaulting to `admin/admin`, would put a known
credential on a port reachable from the internet.

### node-exporter and cAdvisor are not published

Both use `expose` rather than `ports`. Prometheus reaches them over the compose
network, so publishing 9100 and 8080 to the host would widen the attack surface
for no benefit. Neither port is in the security group either.

## A performance problem found and fixed

On the first boot the cAdvisor target came up **down**:

```
cadvisor  down  Get "http://cadvisor:8080/metrics": context deadline exceeded
```

The container logs explained it:

```
fsHandler.go:133] fs: disk usage and inodes count on following dirs took 3.311877025s
```

cAdvisor was walking the overlay2 directories to compute per-container disk
usage. Each scan took 2 to 3 seconds, which pushed the scrape past its timeout,
so the target flapped down for the first minute after every boot. It recovered on
its own, but a target that reliably fails on startup is not worth keeping.

The dashboard only needs `container_cpu_usage_seconds_total`, so the disk
collectors are pure cost. Two changes:

```yaml
command:
  - --docker_only=true
  - --housekeeping_interval=10s
  - --disable_metrics=advtcp,cpu_topology,cpuset,disk,diskIO,hugetlb,memory_numa,percpu,process,referenced_memory,resctrl,sched,tcp,udp
```

```yaml
- job_name: cadvisor
  scrape_timeout: 10s
```

Measured effect:

| | Before | After |
|---|---|---|
| Exposition size | 1724 lines | 663 lines |
| cAdvisor CPU | 34.35 percent | 0.21 percent |
| Cold start behaviour | timeouts for about 60s | connection refused for about 20s, then up |
| `container_cpu_usage_seconds_total` series | present | still present, 9 series |

The remaining 20 seconds is just the container not listening yet, which is normal
and not a scrape failure.

## How to verify it works

All commands run from the repo root.

```bash
cp .env.example .env      # then set GF_SECURITY_ADMIN_PASSWORD
docker compose up -d --build

# 1. All six services running, app healthy
docker compose ps

# 2. Every scrape target up. This is the check that matters most.
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | python3 -c "
import json,sys
for t in json.load(sys.stdin)['data']['activeTargets']:
    print(t['labels']['job'], t['health'], t.get('lastError',''))"

# 3. Generate traffic so the rate()[1m] windows have data
curl -s -X POST 'http://localhost:8080/chaos/errors?rate=0.10'
END=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$END" ]; do
  for _ in 1 2 3 4 5; do
    curl -s -o /dev/null http://localhost:8080/ &
    curl -s -o /dev/null http://localhost:8080/work &
  done
  wait; sleep 0.5
done
curl -s -X POST 'http://localhost:8080/chaos/errors?rate=0'

# 4. Grafana is up and reaches Prometheus
curl -s http://localhost:3000/api/health
curl -s -u admin:$GF_SECURITY_ADMIN_PASSWORD \
  http://localhost:3000/api/datasources/uid/techstream-prometheus/health

# 5. The dashboard provisioned, and the datasource variable has a default
curl -s -u admin:$GF_SECURITY_ADMIN_PASSWORD \
  http://localhost:3000/api/dashboards/uid/techstream-golden-signals

# 6. Open it
open http://localhost:3000/d/techstream-golden-signals
```

Note: do not use `UID` as a shell variable name when scripting these checks. It
is read only in zsh and the assignment fails with "failed to change user ID".

## Verification results

Run against the live stack brought up from the repo root, with fresh volumes.

### Services

All six up. `app` reports healthy.

### Scrape targets

All five up, no `lastError`.

### Panels

Rather than eyeballing the UI, every `expr` was extracted from the committed JSON
and run against the Prometheus API. A query returning no series is exactly a
blank panel in Grafana.

```
14 queries from 12 panels

OK    Error Rate [A]                          = 6.78
OK    p95 Latency [A]                         = 0.3875
OK    Traffic [A]                             = 5.29
OK    CPU Saturation [A]                      = 70.23
OK    Request Latency (p50/p95/p99) [A]       = 0.0393   p50
OK    Request Latency (p50/p95/p99) [B]       = 0.3312   p95
OK    Request Latency (p50/p95/p99) [C]       = 0.4788   p99
OK    Request Rate by Status [A]              = 4.93     (2 series)
OK    Total Request Rate [A]                  = 5.29
OK    Error Ratio (%) with 5% Threshold [A]   = 6.78
OK    5xx Error Rate [A]                      = 0.359
OK    Host CPU Busy % [A]                     = 70.23
OK    Container CPU (cores) [A]               = 0.129    (8 series)
OK    Host Memory Used % [A]                  = 33.84

All 14 queries returned data. No empty panels.
```

Two notes on those numbers. Host CPU at 70 percent and p95 at 388ms are not a
problem, they are the traffic generator saturating the machine, which
incidentally demonstrates the CPU to latency link the RCA depends on. And the
error ratio reading 6.78 percent against an injected 0.10 is the `[1m]` window
still averaging in the error free tail after the rate was reset.

### Grafana

| Check | Result |
|---|---|
| Version | 11.2.2, database ok |
| Datasource | `Prometheus uid=techstream-prometheus default=True` |
| Datasource health | "Successfully queried the Prometheus API" |
| Dashboard | `TechStream Golden Signals`, folder `TechStream` |
| Marked provisioned | `provisioned: True` |
| Datasource variable resolved | `{'text': 'Prometheus', 'value': 'techstream-prometheus'}` |
| Rows | at a glance, Latency, Traffic, Errors, Saturation |
| Panels | 12 |

Three benign messages appear in the Grafana log and can be ignored:

- `plugin xychart is already registered`, a known Grafana 11 warning
- missing `/etc/grafana/provisioning/plugins` and `.../alerting` directories,
  which are optional and not used here
- `Database locked, sleeping then retrying`, SQLite contention during startup

## One behaviour to be aware of

The error ratio expression returns **empty, not zero**, when no 5xx have ever
been recorded. Confirmed by running the same query shape against a status class
with no data:

```
query:  100 * sum(rate(http_requests_total{status=~"4.."}[1m])) / clamp_min(...)
result: []      empty
```

So on a freshly started stack that has served no errors, the error panels are
blank rather than showing 0 percent. Appending `or vector(0)` makes them read
zero:

```promql
(100 * sum(rate(http_requests_total{status=~"5.."}[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 1)) or vector(0)
```

The query is left as specified, because the dashboard and the alert rule are
meant to evaluate the identical expression, and for the alert empty is the
correct behaviour. Worth knowing so a blank Errors panel on a healthy system is
not mistaken for a broken dashboard.

There is a second caveat in the same expression. `clamp_min(..., 1)` forces the
denominator to at least 1 request per second. That avoids divide by zero, but it
also understates the ratio below that traffic level: at 0.5 req/s a real 10
percent error rate reports as 5 percent. The chaos script in Step 4 drives well
above 1 req/s, so the threshold behaves correctly under test. On an idle system
the number is not trustworthy.

## Host metrics on macOS

node-exporter and cAdvisor read `/proc` and `/sys` from whatever kernel they run
on. Under OrbStack or Docker Desktop on a Mac that is the Linux VM, not macOS, so
the host CPU and memory panels describe the VM locally. On the EC2 instance they
describe the real host. The numbers are still useful locally for confirming the
panels work, they are just not measuring macOS.

## Next step

Step 4 adds `chaos/chaos.sh`, which replaces the ad hoc traffic loop above with a
proper incident injector that records its window to `incident.json` for the RCA
in Step 6.
