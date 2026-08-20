# Step 6: Simulated AI root cause analysis

Files: `rca/rca.py`, and its output `rca/rca_report.json` and `rca/rca_report.md`.

## What this step builds

A script that runs after an incident and produces a correlation report. It reads
the window `chaos.sh` recorded, queries Prometheus across it, works out when each
Golden Signal first breached its threshold and by how much, ranks the signals,
and states the most likely trigger in plain language.

Standard library only. No pip install, so it runs on the instance as shipped.

```bash
python3 rca/rca.py
python3 rca/rca.py --prometheus http://1.2.3.4:9090 --incident chaos/incident.json
make rca
```

## What "AI" means here, honestly

There is no model. The analysis is a documented rule set:

1. Read the incident window from `chaos/incident.json`, including the 300 second
   baseline before injection started.
2. Query each signal over that window with `/api/v1/query_range` at a 15s step.
3. Take the **median** of the pre-injection samples as the baseline. Median
   rather than mean, so one spike does not move it.
4. Find the first run of **2 consecutive samples** above the threshold, which is
   30 seconds. One noisy scrape is not an incident.
5. Rank by first breach time, and separately by peak divided by threshold.
6. Decide the verdict from which **class** of signal moved first.

That is deliberate. The output is meant to shorten an incident, and a rule set
can be checked against the timeline table by hand. A model's guess cannot.

## The signals

| Signal | Threshold | Class | Matches an alert |
|---|---|---|---|
| Error ratio | 5 % | application | yes, `HighErrorRate` |
| p95 latency | 0.2 s | application | yes, `HighLatencyP95` |
| Host CPU busy | 85 % | saturation | yes, `HostCpuSaturation` |
| App container CPU | 1.0 core | saturation | no, lab heuristic |
| Request rate | none | context | no, never a trigger |

The first three use the same expressions and thresholds as the alert rules, so
the RCA cannot disagree with what actually paged.

## The verdict logic

```
saturation breached first, application followed   -> resource_exhaustion   -> scale_out
saturation breached, application never did        -> saturation_without_impact -> monitor
error ratio breached first                        -> application_fault     -> restart
latency breached first, no saturation             -> latency_first         -> investigate
nothing breached                                  -> no_threshold_crossings
```

The distinction between the first and third rows is the point of the whole
exercise. It decides whether restarting or scaling is correct:

- **Application fault.** The code failed while resources were fine. A restart
  clears process state and fixes it.
- **Resource exhaustion.** The resource ran out and the app degraded as a
  consequence. A restart achieves nothing, because the new process meets the same
  ceiling. Capacity is the answer.

### Ordering tolerance

Breaches within **30 seconds** of each other are treated as simultaneous, and
saturation takes precedence inside that cohort.

Every signal here is a rate or quantile over a 1 minute window, so a 15 second
difference in first breach time is inside the smoothing and says nothing about
causality. Without this, one sample of jitter could flip the verdict between
"the CPU ran out" and "the app broke", which are opposite conclusions with
opposite remediations.

This earned its place immediately. In the CPU experiment, p95 latency breached at
the same timestamp as container CPU. Left ordered, latency would have won and the
verdict would have been `latency_first`. With the tolerance, saturation correctly
took the trigger.

## All three verdicts, demonstrated on real data

### application_fault, from an errors-mode run

```
Error ratio             peak=    41.788  BREACHED
p95 latency             peak=     0.222  BREACHED
Host CPU busy           peak=    15.828  ok
App container CPU       peak=     0.312  ok
Request rate            peak=        20  ok

VERDICT: application_fault (confidence high)
```

Error ratio breached first at 8.36x its threshold, and no saturation signal
breached at all, so the host had resources to spare while the app returned
errors. Recommended remediation: `restart`. That is what the automation did.

### saturation_without_impact, from a light CPU run

```
p95 latency             peak=     0.117  ok
Host CPU busy           peak=       100  BREACHED
App container CPU       peak=     3.891  BREACHED

VERDICT: saturation_without_impact (confidence medium)
```

Both CPU signals pinned, but latency stayed under threshold, so the pressure
never became user visible. Recommended remediation: `monitor`. Neither restarting
nor scaling is justified without impact.

### resource_exhaustion, from a heavy CPU run at 30 req/s

```
p95 latency             peak=     0.939  BREACHED
Host CPU busy           peak=    99.983  BREACHED
App container CPU       peak=     3.805  BREACHED

VERDICT: resource_exhaustion (confidence medium)
lead_times: {'container_cpu': 15, 'host_cpu': 30}
concurrent: ['p95 latency', 'Host CPU busy']
```

Recommended remediation: `scale_out`, **not** restart. Confidence is medium
rather than high because no application signal breached more than 30 seconds
after the saturation, so the ordering evidence is weaker than the mechanism.

## Establishing that errors actually stopped

The naive reading of the data is wrong here, and the script says so.

After a restart the app is a fresh process with counters at zero. With the error
rate cleared, no 5xx ever occurs, so `http_requests_total{status=~"5.."}` stops
existing rather than reporting zero. The error ratio expression then returns no
data, and there are no samples below threshold to confirm recovery from.

Treating that absence as recovery would be wrong, because a completely dead app
produces exactly the same absence. So the script checks whether traffic continued
through the gap:

```
traffic present + no error ratio samples  ->  requests succeeded, errors ceased
no traffic at all                         ->  nothing was being measured
```

From the committed report:

```
Errors ceased at: 2026-08-17T13:32:12Z
From first breach to cessation: 90s
Traffic samples after the last error: 19 at a mean of 16.82 req/s
```

19 samples of continuing traffic at 16.8 req/s with no 5xx among them. Requests
were being served and none failed, which rules out the "measurement stopped"
explanation. The report states this is inferred, not read directly.

## How to verify it works

```bash
# Error handling
python3 rca/rca.py --incident /nonexistent.json     # clear message, exit 1
python3 rca/rca.py --prometheus http://localhost:9999 # names the connection failure

# Real run, after a chaos experiment
make chaos-errors
sleep 90        # let the whole query window fall into the past
make rca
less rca/rca_report.md

# Determinism: two runs must agree
python3 rca/rca.py && cp rca/rca_report.md /tmp/r1.md
python3 rca/rca.py
diff <(grep -v '^Generated' /tmp/r1.md) <(grep -v '^Generated' rca/rca_report.md)
```

## Verification results

| Check | Result |
|---|---|
| Missing incident file | `error: incident file not found`, plus the command to fix it, exit 1 |
| Unreachable Prometheus | `error: cannot reach Prometheus at ...: Connection refused` |
| Malformed incident JSON | rejected with the parse error |
| errors-mode run | `application_fault`, confidence high |
| light cpu-mode run | `saturation_without_impact`, confidence medium |
| heavy cpu-mode run | `resource_exhaustion`, confidence medium, recommends scale_out |
| Determinism | two runs byte identical apart from the generated timestamp |
| Clean baseline | host CPU 1.459 % to 15.828 %, container CPU 0.005 to 0.312 cores |
| Restart correlation | `app_restart_count: 1`, cessation inferred with traffic evidence |
| Output | `rca_report.json` and `rca_report.md` both written |

## Three problems found and fixed

### 1. CPU saturation produced almost no latency signal

The brief's example verdict is "CPU saturation preceded the latency rise", so that
causal chain has to exist. It barely did.

Pushed to four times core oversubscription, 16 stress workers on 4 cores at
**589 percent** container CPU, p95 latency only reached **0.185s**. The cause was
in the app, not the RCA: request latency was dominated by `time.sleep()`, and a
sleep takes its wall clock time regardless of CPU pressure. Benchmarked in the
real image, the "CPU work" part was 0.7ms:

```
   1500 iterations ->   0.70 ms of CPU
  25000 iterations ->  10.3  ms of CPU
```

Fixed in the app by raising `CPU_WORK_ITERATIONS` to 25000 and lowering
`BASE_LATENCY_MS` to 15, keeping baseline latency in the same range while making
the CPU-bound share dominate. p95 now moves from about 0.07s idle to 0.25s at 30
req/s with cores saturated, and up to 0.939s sustained. Step 2's documentation
was corrected, since it had claimed a stronger effect than existed.

### 2. The latency threshold was calibrated by guesswork

`HighLatencyP95` was set at 0.5s. Measurement showed the app's idle p95 is about
0.07s, so 0.5s meant it could get seven times slower than normal before anything
said so. It is now 0.2s, roughly 3x baseline, in both `alerts.yml` and `rca.py`.

Worth knowing: 0.2s can be reached by load alone, without any CPU chaos, since
p95 at 20 req/s sits near 0.203s. So latency breaching does **not** by itself
imply saturation. That is precisely why the RCA evaluates CPU separately rather
than inferring saturation from latency.

### 3. Baselines were silently contaminated

A report generated after back-to-back experiments contained this:

| Signal | Baseline | Peak |
|---|---|---|
| p95 latency | 0.384 s | 0.203 s |
| App container CPU | 2.115 cores | 0.249 cores |

The baseline was worse than the incident peak, because the 300 second baseline
pad reached into the tail of the previous CPU experiment. Every "times normal"
figure was meaningless, and a table showing baseline above peak reads as a broken
tool.

The script now detects it and says so explicitly, naming the likely cause and
noting that threshold crossings, ranking and the verdict are unaffected because
none of them use the baseline. `make loop` leaves a 5 minute idle gap for this
reason.

Confirmed fixed: the committed report has a clean baseline and flags no
contamination.

## A note on determinism

One earlier report showed a host CPU peak of 64.437 percent where a later run over
the same window gave 11.963 percent. That report was generated one second after
the chaos run ended, when the query window still extended into the future and
Prometheus had not finished ingesting the range.

Re-querying the same window twice now returns 11.963 both times, matching a direct
`query_range` call, and node-exporter never dropped a scrape. Two consecutive RCA
runs produce byte identical reports. The lesson is in the verification steps
above: wait until the whole query window is in the past before analysing. `make
loop` waits 90 seconds.

## Optional: Amazon DevOps Guru

Not enabled, and worth being clear about why it would only partly help.

DevOps Guru reads CloudWatch. It would see EC2 host CPU, network and disk, and
ASG behaviour if one existed. It would **not** see the application 5xx rate,
because that lives in Prometheus and is never published to CloudWatch. For the
`errors` scenario, which is the one this lab remediates, DevOps Guru would report
nothing unusual: host CPU was 15.8 percent at peak while 771 requests failed.

To make a fair comparison you would first have to publish
`http_requests_total`-derived metrics to CloudWatch with the agent or a custom
metric writer. Without that, the simulated RCA is not merely cheaper, it is the
only one of the two that can see the fault.

## Next

The Makefile, README and runbook, which tie the whole loop together with the real
timestamps from these runs.
