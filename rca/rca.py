#!/usr/bin/env python3
"""Simulated AI root cause analysis for a TechStream incident.

Reads the incident window written by chaos.sh, queries the Prometheus HTTP API
across that window, works out when each Golden Signal first breached its
threshold and by how much, ranks the signals by which moved first and which
deviated most, and states the most likely trigger in plain language.

Writes rca_report.json and rca_report.md.

Standard library only. No pip install, so it runs on the instance as shipped.

There is no machine learning here. The "AI" is a documented set of rules:
threshold crossing detection, ordering by first breach, magnitude ranking, and a
small decision tree over which class of signal moved first. That is deliberate.
The reasoning is auditable, which matters more than sophistication when the
output is meant to shorten an incident.

    python3 rca/rca.py
    python3 rca/rca.py --prometheus http://1.2.3.4:9090 --incident chaos/incident.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# ---------------------------------------------------------------- signal setup

# Thresholds are lab heuristics, matched to the alert rules where one exists.
# error_ratio and host_cpu mirror alerts.yml exactly so the RCA agrees with what
# actually paged. The others are judgement calls, documented in the report.
SIGNALS = [
    {
        "key": "error_ratio",
        "label": "Error ratio",
        "unit": "%",
        "query": (
            '100 * sum(rate(http_requests_total{status=~"5.."}[1m])) '
            "/ clamp_min(sum(rate(http_requests_total[1m])), 1)"
        ),
        "threshold": 5.0,
        "kind": "application",
        "note": "Same expression as the HighErrorRate alert.",
    },
    {
        "key": "p95_latency",
        "label": "p95 latency",
        "unit": "s",
        "query": (
            "histogram_quantile(0.95, "
            "sum(rate(http_request_duration_seconds_bucket[1m])) by (le))"
        ),
        "threshold": 0.2,
        "kind": "application",
        "note": (
            "Same expression and threshold as the HighLatencyP95 alert. Calibrated "
            "from measurement: idle baseline p95 is about 0.07s, and about 0.25s "
            "with the cores saturated, so 0.2s is roughly 3x normal."
        ),
    },
    {
        "key": "host_cpu",
        "label": "Host CPU busy",
        "unit": "%",
        "query": '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)',
        "threshold": 85.0,
        "kind": "saturation",
        "note": "Same expression and threshold as the HostCpuSaturation alert.",
    },
    {
        "key": "container_cpu",
        "label": "App container CPU",
        "unit": "cores",
        "query": (
            "sum(rate(container_cpu_usage_seconds_total"
            '{name="techstream-app"}[1m]))'
        ),
        "threshold": 1.0,
        "kind": "saturation",
        "note": "1.0 means one full core. Lab heuristic, no matching alert.",
    },
    {
        "key": "traffic",
        "label": "Request rate",
        "unit": "req/s",
        "query": "sum(rate(http_requests_total[1m]))",
        "threshold": None,
        "kind": "context",
        "note": "Context only. Never a trigger, but needed to read the others.",
    },
]

# A breach has to persist for this many consecutive samples before it counts.
# At a 15s step that is 30 seconds. One noisy scrape is not an incident, and
# this mirrors the spirit of the alert rule's "for" clause.
MIN_CONSECUTIVE = 2

STEP_SECONDS = 15

# Breaches closer together than this are treated as simultaneous rather than
# ordered. Every signal here is a rate or quantile over a 1 minute window, so a
# 15 or 30 second difference in first breach time is inside the smoothing and
# says nothing about causality. Without this, a single sample of jitter could
# flip the verdict between "the CPU ran out" and "the app broke", which are
# opposite conclusions with opposite remediations.
SIMULTANEITY_TOLERANCE_SECONDS = 30


# ------------------------------------------------------------------- prometheus


def query_range(prom_url: str, query: str, start: float, end: float, step: int) -> list:
    """Call /api/v1/query_range and return [(timestamp, value), ...].

    Non-finite values, which histogram_quantile produces when a window contains
    no requests, are dropped rather than treated as zero. Treating NaN as zero
    would invent a healthy latency reading out of an absence of traffic.
    """
    params = urllib.parse.urlencode(
        {"query": query, "start": f"{start:.0f}", "end": f"{end:.0f}", "step": str(step)}
    )
    url = f"{prom_url.rstrip('/')}/api/v1/query_range?{params}"

    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise RuntimeError(f"Prometheus returned HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"cannot reach Prometheus at {prom_url}: {exc.reason}") from exc

    if body.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {body.get('error', 'unknown')}")

    result = body["data"]["result"]
    if not result:
        return []

    samples = []
    for ts, raw in result[0]["values"]:
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if math.isfinite(value):
            samples.append((float(ts), value))
    return samples


# --------------------------------------------------------------------- analysis


def first_sustained_breach(samples: list, threshold: float, minimum: int) -> tuple | None:
    """First timestamp beginning a run of at least `minimum` samples above threshold."""
    run_start = None
    run_length = 0

    for ts, value in samples:
        if value > threshold:
            if run_start is None:
                run_start = ts
            run_length += 1
            if run_length >= minimum:
                return run_start, value
        else:
            run_start = None
            run_length = 0
    return None


def first_sustained_recovery(
    samples: list, threshold: float, after_ts: float, minimum: int
) -> float | None:
    """First timestamp after `after_ts` beginning a sustained run below threshold."""
    run_start = None
    run_length = 0

    for ts, value in samples:
        if ts <= after_ts:
            continue
        if value <= threshold:
            if run_start is None:
                run_start = ts
            run_length += 1
            if run_length >= minimum:
                return run_start
        else:
            run_start = None
            run_length = 0
    return None


def analyse_signal(signal: dict, samples: list, windows: dict) -> dict:
    """Baseline, peak, breach timing and deviation for one signal."""
    inject_start = windows["injection"]["start_epoch"]

    baseline_samples = [v for ts, v in samples if ts < inject_start]
    incident_samples = [(ts, v) for ts, v in samples if ts >= inject_start]

    out = {
        "key": signal["key"],
        "label": signal["label"],
        "unit": signal["unit"],
        "kind": signal["kind"],
        "query": signal["query"],
        "threshold": signal["threshold"],
        "note": signal["note"],
        "sample_count": len(samples),
        "baseline_sample_count": len(baseline_samples),
        "data_available": bool(samples),
    }

    if not samples:
        out.update(
            {
                "baseline": None,
                "peak": None,
                "peak_at": None,
                "breached": False,
                "first_breach_at": None,
                "recovered_at": None,
                "seconds_to_recover": None,
                "peak_over_threshold": None,
                "peak_over_baseline": None,
                "reason": "no data returned for this query over the window",
            }
        )
        return out

    baseline = statistics.median(baseline_samples) if baseline_samples else None
    peak_ts, peak = max(incident_samples or samples, key=lambda p: p[1])

    out["baseline"] = round(baseline, 4) if baseline is not None else None
    out["peak"] = round(peak, 4)
    out["peak_at"] = iso(peak_ts)
    out["peak_at_epoch"] = peak_ts

    # A baseline worse than the incident peak means the pre-injection window was
    # not quiet. The usual cause is running experiments back to back, so the
    # 300 second baseline pad reaches into the tail of the previous one. Flag it,
    # because a contaminated baseline makes every "times normal" figure wrong,
    # and silently reporting baseline > peak looks like a broken tool.
    out["baseline_contaminated"] = bool(
        baseline is not None and baseline > peak
    )
    if out["baseline_contaminated"]:
        out["baseline_warning"] = (
            f"Baseline ({baseline:.4g}) exceeds the incident peak ({peak:.4g}). The "
            "window before injection was not quiet, most likely because a previous "
            "experiment was still draining. Treat baseline comparisons for this "
            "signal as unreliable. Threshold crossings are unaffected, since they do "
            "not use the baseline."
        )

    threshold = signal["threshold"]
    if threshold is None:
        out.update(
            {
                "breached": False,
                "first_breach_at": None,
                "recovered_at": None,
                "seconds_to_recover": None,
                "peak_over_threshold": None,
                "peak_over_baseline": ratio_or_none(peak, baseline),
                "reason": "context signal, no threshold applied",
            }
        )
        return out

    breach = first_sustained_breach(incident_samples, threshold, MIN_CONSECUTIVE)

    if breach is None:
        out.update(
            {
                "breached": False,
                "first_breach_at": None,
                "recovered_at": None,
                "seconds_to_recover": None,
                "peak_over_threshold": round(peak / threshold, 3) if threshold else None,
                "peak_over_baseline": ratio_or_none(peak, baseline),
                "reason": f"peak {peak:.4g} never held above {threshold:.4g} "
                f"for {MIN_CONSECUTIVE} consecutive samples",
            }
        )
        return out

    breach_ts, breach_value = breach
    recovered_ts = first_sustained_recovery(
        incident_samples, threshold, breach_ts, MIN_CONSECUTIVE
    )

    out.update(
        {
            "breached": True,
            "first_breach_at": iso(breach_ts),
            "first_breach_at_epoch": breach_ts,
            "value_at_first_breach": round(breach_value, 4),
            "recovered_at": iso(recovered_ts) if recovered_ts else None,
            "recovered_at_epoch": recovered_ts,
            "seconds_to_recover": round(recovered_ts - breach_ts) if recovered_ts else None,
            "peak_over_threshold": round(peak / threshold, 3),
            "peak_over_baseline": ratio_or_none(peak, baseline),
            "exceeded_threshold_by": round(peak - threshold, 4),
            "reason": None,
        }
    )
    return out


def describe_gap(seconds: float) -> str:
    """Plain language for a breach gap, honest about what is inside the noise."""
    seconds = round(seconds)
    if seconds <= 0:
        return "breached at the same time"
    if seconds <= SIMULTANEITY_TOLERANCE_SECONDS:
        return f"breached {seconds}s later, within the smoothing window"
    return f"followed {seconds}s later"


def ratio_or_none(peak: float, baseline: float | None) -> float | None:
    if baseline is None or baseline == 0:
        return None
    return round(peak / baseline, 3)


def rank_signals(analyses: list) -> dict:
    breached = [a for a in analyses if a.get("breached")]

    moved_first = sorted(breached, key=lambda a: a["first_breach_at_epoch"])
    deviated_most = sorted(
        breached, key=lambda a: a.get("peak_over_threshold") or 0, reverse=True
    )

    return {
        "moved_first": [
            {
                "rank": i + 1,
                "key": a["key"],
                "label": a["label"],
                "first_breach_at": a["first_breach_at"],
                "seconds_after_first": round(
                    a["first_breach_at_epoch"] - moved_first[0]["first_breach_at_epoch"]
                ),
            }
            for i, a in enumerate(moved_first)
        ],
        "deviated_most": [
            {
                "rank": i + 1,
                "key": a["key"],
                "label": a["label"],
                "peak": a["peak"],
                "unit": a["unit"],
                "threshold": a["threshold"],
                "peak_over_threshold": a["peak_over_threshold"],
            }
            for i, a in enumerate(deviated_most)
        ],
    }


def infer_trigger(analyses: list, incident: dict) -> dict:
    """Decision tree over which class of signal breached first.

    Saturation first means the resource ran out and the application degraded as a
    consequence. Application first means the code failed while resources were
    fine. The distinction decides whether restarting or scaling is the right
    remediation, which is the whole point of producing this report.
    """
    by_key = {a["key"]: a for a in analyses}
    breached = [a for a in analyses if a.get("breached")]

    if not breached:
        return {
            "verdict": "no_threshold_crossings",
            "confidence": "low",
            "headline": "No signal held above its threshold during the incident window.",
            "explanation": (
                "Either the injected fault was too small or too short to cross a "
                "threshold, or the incident window in incident.json does not line up "
                "with when the fault actually happened. Check that chaos.sh and "
                "Prometheus agree on the clock, and that the run was long enough for "
                "the 1 minute rate windows to fill."
            ),
            "lead_times": {},
        }

    ordered = sorted(breached, key=lambda a: a["first_breach_at_epoch"])
    first_ts = ordered[0]["first_breach_at_epoch"]

    lead_times = {
        a["key"]: round(a["first_breach_at_epoch"] - first_ts)
        for a in ordered[1:]
    }

    # Everything that breached within the tolerance of the earliest counts as
    # having moved first. Saturation takes precedence inside that cohort, because
    # CPU exhaustion causing slow requests is a real mechanism, while slow
    # requests causing CPU exhaustion is not.
    cohort = [
        a
        for a in ordered
        if a["first_breach_at_epoch"] - first_ts <= SIMULTANEITY_TOLERANCE_SECONDS
    ]
    saturation_in_cohort = [a for a in cohort if a["kind"] == "saturation"]
    first = saturation_in_cohort[0] if saturation_in_cohort else cohort[0]

    concurrent = [a["label"] for a in cohort if a["key"] != first["key"]]

    saturation_breached = [a for a in breached if a["kind"] == "saturation"]
    application_breached = [a for a in breached if a["kind"] == "application"]

    errors = by_key.get("error_ratio", {})
    latency = by_key.get("p95_latency", {})

    if first["kind"] == "saturation" and not application_breached:
        return {
            "verdict": "saturation_without_impact",
            "confidence": "medium",
            "headline": (
                f"{first['label']} saturated, but no application signal degraded "
                "past its threshold."
            ),
            "explanation": (
                f"{first['label']} crossed its threshold at "
                f"{first['first_breach_at']}, peaking at {first['peak']} "
                f"{first['unit']}. Error ratio and latency both stayed within "
                "threshold throughout, so the resource pressure did not become "
                "user visible. This is capacity headroom being consumed rather "
                "than an incident. Restarting would achieve nothing, and there is "
                "no user impact yet to justify scaling. Worth watching, not worth "
                "paging."
            ),
            "recommended_remediation": "monitor",
            "lead_times": lead_times,
        }

    if first["kind"] == "saturation" and application_breached:
        first_lead = first["first_breach_at_epoch"]
        followers = ", ".join(
            f"{a['label'].lower()} {describe_gap(a['first_breach_at_epoch'] - first_lead)}"
            for a in ordered
            if a["kind"] == "application"
        )
        return {
            "verdict": "resource_exhaustion",
            "confidence": "high" if any(
                a["first_breach_at_epoch"] - first_lead > SIMULTANEITY_TOLERANCE_SECONDS
                for a in ordered
                if a["kind"] == "application"
            ) else "medium",
            "headline": (
                f"{first['label']} saturation preceded or coincided with the "
                "application symptoms, consistent with resource exhaustion."
            ),
            "explanation": (
                f"{first['label']} crossed its threshold at "
                f"{first['first_breach_at']}, peaking at {first['peak']} "
                f"{first['unit']} against a threshold of {first['threshold']}. "
                f"Application signals: {followers}. "
                + (
                    f"Breaches within {SIMULTANEITY_TOLERANCE_SECONDS}s of each other "
                    "are treated as simultaneous, because every signal here is "
                    "smoothed over a 1 minute window and finer ordering is not "
                    "meaningful. "
                    if concurrent
                    else ""
                )
                + "A restart will not help, because the new process meets the same "
                "resource ceiling. Adding capacity is the appropriate response, "
                "which is what the scale-out option exists for."
            ),
            "recommended_remediation": "scale_out",
            "lead_times": lead_times,
            "concurrent_within_tolerance": concurrent,
        }

    if first["key"] == "error_ratio":
        no_saturation = not saturation_breached
        return {
            "verdict": "application_fault",
            "confidence": "high" if no_saturation else "medium",
            "headline": (
                "The error ratio breached first, consistent with an application "
                "fault rather than resource exhaustion."
            ),
            "explanation": (
                f"Error ratio crossed 5 percent first at {first['first_breach_at']}, "
                f"peaking at {errors.get('peak')} percent, which is "
                f"{errors.get('peak_over_threshold')} times the alert threshold. "
                + (
                    "No saturation signal breached at any point in the window, so the "
                    "host and container had resources to spare while the application "
                    "was returning errors. "
                    if no_saturation
                    else "Saturation signals also breached, but later, so they are more "
                    "likely a consequence than a cause. "
                )
                + "Restarting the process is the correct remediation for a fault that "
                "lives in process state, and that is what the automation does."
            ),
            "recommended_remediation": "restart",
            "lead_times": lead_times,
        }

    if first["key"] == "p95_latency":
        return {
            "verdict": "latency_first",
            "confidence": "medium",
            "headline": (
                "Latency degraded before errors appeared, with no preceding "
                "saturation breach."
            ),
            "explanation": (
                f"p95 latency crossed {latency.get('threshold')}s first at "
                f"{first['first_breach_at']}, peaking at {latency.get('peak')}s. "
                "Errors, if they appeared, came later. With CPU below threshold this "
                "pattern usually points at something the app waits on rather than "
                "the app itself: a slow dependency, a lock, or an exhausted "
                "connection pool. None of those are modelled in this lab, so treat "
                "this verdict as a shape to recognise rather than a finding."
            ),
            "recommended_remediation": "investigate",
            "lead_times": lead_times,
        }

    return {
        "verdict": "inconclusive",
        "confidence": "low",
        "headline": f"{first['label']} breached first, but the pattern does not match a known shape.",
        "explanation": (
            "The signal that moved first is neither an application error nor a "
            "recognised saturation lead. Inspect the timeline table below directly."
        ),
        "recommended_remediation": "investigate",
        "lead_times": lead_times,
    }


def infer_error_cessation(analyses: list, raw_samples: dict) -> dict:
    """Decide whether errors actually stopped, when the 5xx series simply vanished.

    After a restart the app exports no 5xx series at all, so the error ratio
    expression returns nothing. Absence is not the same as zero, so this does not
    assume recovery. Instead it checks whether traffic was still flowing during
    the gap:

      traffic present + no error ratio samples  ->  requests succeeded, errors ceased
      no traffic at all                         ->  nothing was being measured

    That distinction is the difference between a real recovery and a blind spot.
    """
    errors = next((a for a in analyses if a["key"] == "error_ratio"), {})

    if not errors.get("breached"):
        return {"inferred": False, "reason": "error ratio never breached"}

    if errors.get("recovered_at"):
        return {
            "inferred": False,
            "reason": "recovery observed directly from samples below threshold",
        }

    breach_ts = errors.get("first_breach_at_epoch")
    error_samples = raw_samples.get("error_ratio", [])
    traffic_samples = raw_samples.get("traffic", [])

    last_error_ts = max((ts for ts, _ in error_samples), default=None)
    if last_error_ts is None:
        return {"inferred": False, "reason": "no error ratio samples at all"}

    traffic_after = [(ts, v) for ts, v in traffic_samples if ts > last_error_ts and v > 0]

    if not traffic_after:
        return {
            "inferred": False,
            "reason": (
                "the error ratio series ends, but no traffic was recorded afterwards "
                "either, so nothing can be concluded. Traffic stopped, which is a "
                "measurement gap rather than a recovery."
            ),
        }

    span = round(traffic_after[-1][0] - last_error_ts)
    mean_rps = round(statistics.mean(v for _, v in traffic_after), 2)

    return {
        "inferred": True,
        "errors_ceased_at": iso(last_error_ts),
        "errors_ceased_at_epoch": last_error_ts,
        "seconds_from_breach_to_cessation": round(last_error_ts - breach_ts)
        if breach_ts
        else None,
        "evidence": (
            f"The 5xx series stops after {iso(last_error_ts)}, while traffic kept "
            f"flowing for a further {span}s at a mean of {mean_rps} req/s across "
            f"{len(traffic_after)} samples. Requests were still being served and none "
            "of them failed, so errors genuinely ceased rather than measurement "
            "stopping."
        ),
        "traffic_samples_after": len(traffic_after),
        "mean_rps_after": mean_rps,
    }


def correlate_remediation(incident: dict, analyses: list, raw_samples: dict) -> dict:
    """Tie the restart evidence to when the error ratio recovered."""
    restarts = incident.get("app_restart_count") or 0
    errors = next((a for a in analyses if a["key"] == "error_ratio"), {})
    cessation = infer_error_cessation(analyses, raw_samples)

    out = {
        "app_restart_count": restarts,
        "app_restarted_during_run": bool(incident.get("app_restarted_during_run")),
        "error_ratio_recovered_at": errors.get("recovered_at"),
        "seconds_from_breach_to_recovery": errors.get("seconds_to_recover"),
        "error_cessation_inference": cessation,
    }

    if restarts and cessation.get("inferred"):
        out["assessment"] = (
            f"The app container restarted {restarts} time(s) during the window. "
            f"{cessation['evidence']} Consistent with automated remediation "
            "resolving the incident."
        )
        out["caveat"] = (
            "Recovery here is inferred rather than read directly. After a restart the "
            "app is a fresh process with counters at zero, so the 5xx series stops "
            "existing rather than reporting zero, and the error ratio expression "
            "returns no data. The inference above is only sound because traffic "
            "continued through the gap, which rules out the alternative explanation "
            "that measurement simply stopped."
        )
        return out

    if restarts and errors.get("recovered_at"):
        out["assessment"] = (
            f"The app container restarted {restarts} time(s) during the window, and "
            "the error ratio returned below threshold afterwards. Consistent with "
            "automated remediation resolving the incident."
        )
    elif restarts:
        out["assessment"] = (
            f"The app container restarted {restarts} time(s), but recovery could not "
            "be confirmed from the data. "
            f"{cessation.get('reason', '')} "
            "Either the restart did not address the cause, or the window ended too "
            "early, or traffic stopped before recovery could be measured."
        )
    elif errors.get("recovered_at"):
        out["assessment"] = (
            "The error ratio recovered without any restart being detected. The fault "
            "cleared on its own, or the chaos injection simply ended."
        )
    else:
        out["assessment"] = "No restart detected and no recovery observed in the window."

    # Honest caveat about how the error ratio actually clears after a restart.
    out["caveat"] = (
        "After a restart the app is a fresh process with counters at zero, so the 5xx "
        "series stops existing rather than reporting zero. The error ratio expression "
        "then returns no data, which reads as recovery. The outcome is correct, but "
        "absence of data and a genuine zero are not the same thing."
    )
    return out


# ----------------------------------------------------------------------- output


def iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt(value, unit: str = "", places: int = 3) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        text = f"{value:.{places}f}".rstrip("0").rstrip(".")
        return f"{text}{unit}" if unit else text
    return f"{value}{unit}" if unit else str(value)


def build_markdown(report: dict) -> str:
    inc = report["incident"]
    trig = report["trigger"]
    rem = report["remediation"]

    lines = [
        "# Root cause analysis: TechStream incident",
        "",
        f"Generated {report['generated_at']} by `rca/rca.py`.",
        "",
        "> **This is a lab.** Every request in this window was generated by",
        "> `chaos/chaos.sh`. No real users were affected and no production system",
        "> was involved. The fault was injected deliberately.",
        "",
        "## Verdict",
        "",
        f"**{trig['headline']}**",
        "",
        f"- Verdict: `{trig['verdict']}`",
        f"- Confidence: {trig['confidence']}",
        f"- Recommended remediation: `{trig.get('recommended_remediation', 'n/a')}`",
        "",
        trig["explanation"],
        "",
        "## Incident window",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Chaos mode | `{inc.get('mode')}` |",
        f"| Injected error rate | {inc.get('parameters', {}).get('error_rate')} |",
        f"| Injected CPU cores | {inc.get('parameters', {}).get('cpus')} |",
        f"| Started | {inc.get('started_at')} |",
        f"| Injection ended | {inc.get('injection_ended_at')} |",
        f"| Run ended | {inc.get('ended_at')} |",
        f"| Duration | {inc.get('duration_seconds')}s |",
        f"| Requests sent | {inc.get('requests', {}).get('sent')} |",
        f"| 5xx responses | {inc.get('requests', {}).get('http_5xx')} |",
        f"| Observed rate | {inc.get('requests', {}).get('observed_rps')} req/s |",
        "",
        "## Signal timeline",
        "",
        "Ordered by when each signal first breached. A breach has to hold for "
        f"{MIN_CONSECUTIVE} consecutive samples ({MIN_CONSECUTIVE * STEP_SECONDS}s) "
        "before it counts, so a single noisy scrape is not treated as an incident.",
        "",
        "| Signal | Baseline | Peak | Threshold | Peak vs threshold | First breach | Lead | Recovered |",
        "|---|---|---|---|---|---|---|---|",
    ]

    ordered = sorted(
        report["signals"],
        key=lambda a: (
            not a.get("breached"),
            a.get("first_breach_at_epoch") or float("inf"),
        ),
    )
    lead = trig.get("lead_times", {})

    for sig in ordered:
        breach = sig.get("first_breach_at") or "not breached"
        lead_text = "first" if sig.get("breached") and sig["key"] not in lead else (
            f"+{lead[sig['key']]}s" if sig["key"] in lead else "-"
        )
        if not sig.get("breached"):
            lead_text = "-"
        lines.append(
            "| {label} | {baseline} | {peak} | {threshold} | {mult} | {breach} | {lead} | {rec} |".format(
                label=sig["label"],
                baseline=fmt(sig.get("baseline"), " " + sig["unit"]),
                peak=fmt(sig.get("peak"), " " + sig["unit"]),
                threshold=fmt(sig.get("threshold"), " " + sig["unit"]) if sig.get("threshold") is not None else "none",
                mult=f"{sig['peak_over_threshold']}x" if sig.get("peak_over_threshold") else "-",
                breach=breach,
                lead=lead_text,
                rec=sig.get("recovered_at") or "-",
            )
        )

    lines += ["", "## Ranking", "", "**Which moved first**", ""]
    if report["ranking"]["moved_first"]:
        for row in report["ranking"]["moved_first"]:
            suffix = "" if row["seconds_after_first"] == 0 else f", {row['seconds_after_first']}s later"
            lines.append(f"{row['rank']}. {row['label']} at {row['first_breach_at']}{suffix}")
    else:
        lines.append("No signal breached its threshold.")

    lines += ["", "**Which deviated most**", ""]
    if report["ranking"]["deviated_most"]:
        for row in report["ranking"]["deviated_most"]:
            lines.append(
                f"{row['rank']}. {row['label']} peaked at {fmt(row['peak'])} {row['unit']}, "
                f"{row['peak_over_threshold']}x its threshold of {fmt(row['threshold'])}"
            )
    else:
        lines.append("No signal breached its threshold.")

    lines += [
        "",
        "## Remediation correlation",
        "",
        f"- Restarts detected during the run: **{rem['app_restart_count']}**",
        f"- Error ratio recovered at: "
        + (
            rem["error_ratio_recovered_at"]
            if rem["error_ratio_recovered_at"]
            else (
                "not observed directly, see the cessation evidence below"
                if (rem.get("error_cessation_inference") or {}).get("inferred")
                else "not observed within the window"
            )
        ),
        f"- Time from first breach to recovery: "
        f"{fmt(rem['seconds_from_breach_to_recovery'], 's', 0)}",
        "",
        rem["assessment"],
        "",
        f"*Caveat.* {rem['caveat']}",
        "",
    ]

    cess = rem.get("error_cessation_inference") or {}
    if cess.get("inferred"):
        lines += [
            "### How cessation was established",
            "",
            f"- Errors ceased at: **{cess['errors_ceased_at']}**",
            f"- From first breach to cessation: "
            f"{fmt(cess.get('seconds_from_breach_to_cessation'), 's', 0)}",
            f"- Traffic samples after the last error: {cess['traffic_samples_after']} "
            f"at a mean of {cess['mean_rps_after']} req/s",
            "",
            cess["evidence"],
            "",
        ]

    contaminated = [s for s in report["signals"] if s.get("baseline_contaminated")]
    if contaminated:
        lines += [
            "### Warning: contaminated baseline",
            "",
            "For the following signals the pre-injection baseline is worse than the "
            "incident peak, so the window before injection was not quiet:",
            "",
        ]
        for sig in contaminated:
            lines.append(
                f"- **{sig['label']}**: baseline {fmt(sig['baseline'])} "
                f"{sig['unit']} against peak {fmt(sig['peak'])} {sig['unit']}"
            )
        lines += [
            "",
            "The usual cause is running experiments back to back, so the 300 second "
            "baseline pad reaches into the tail of the previous one. Leave a few "
            "minutes of idle time between runs for clean baselines.",
            "",
            "Threshold crossings, the ranking and the verdict are unaffected, because "
            "none of them use the baseline. Only the 'times normal' comparisons are.",
            "",
        ]

    baseline_note = report.get("detection_rules", {}).get("baseline_note")
    if baseline_note:
        missing = ", ".join(report["detection_rules"]["signals_without_baseline"])
        lines += [
            "### Signals without a baseline",
            "",
            f"No pre-injection samples for: {missing}.",
            "",
            baseline_note,
            "",
        ]

    lines += [
        "## How this analysis works",
        "",
        "No machine learning is involved. The steps are:",
        "",
        "1. Read the incident window from `chaos/incident.json`, including a "
        "300 second baseline before injection started.",
        "2. Query each signal over that window with `/api/v1/query_range` at a "
        f"{STEP_SECONDS}s step.",
        "3. Take the median of the pre-injection samples as the baseline. Median "
        "rather than mean, so one spike does not move it.",
        f"4. Find the first run of {MIN_CONSECUTIVE} consecutive samples above the "
        "threshold, and the first sustained run back below it.",
        "5. Rank by first breach time and by peak divided by threshold.",
        "6. Decide the verdict from which class of signal moved first: saturation "
        "first reads as resource exhaustion, application error first reads as an "
        "application fault.",
        "",
        "The reasoning is a documented rule set rather than a model, which means "
        "the conclusion can be checked against the table above by hand.",
        "",
        "## Caveats",
        "",
        "- Traffic is synthetic, generated by `chaos.sh`. Absolute request rates "
        "mean nothing outside this lab.",
        "- The error ratio uses `clamp_min(..., 1)` on the denominator. Below "
        "1 request per second it understates the true ratio, so the number is only "
        "trustworthy while traffic is flowing.",
        "- `histogram_quantile` returns NaN when a window has no requests. Those "
        "samples are dropped, not read as zero, so latency gaps appear as missing "
        "data rather than as fast responses.",
        "- Host CPU comes from node_exporter, which reads the kernel it runs on. "
        "Under Docker Desktop or OrbStack on a Mac that is the Linux VM, not macOS.",
        "- Thresholds for error ratio, latency and host CPU match the alert rules. "
        "The container CPU threshold of 1 core is a lab heuristic with no "
        "corresponding alert.",
    ]

    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Correlate a TechStream incident and produce an RCA report."
    )
    parser.add_argument(
        "--incident",
        default=os.path.join(os.path.dirname(__file__), "..", "chaos", "incident.json"),
        help="Incident window written by chaos.sh. Default chaos/incident.json",
    )
    parser.add_argument(
        "--prometheus",
        default=os.getenv("PROMETHEUS_URL", "http://localhost:9090"),
        help="Prometheus base URL. Default http://localhost:9090",
    )
    parser.add_argument(
        "--out-dir",
        default=os.path.dirname(os.path.abspath(__file__)),
        help="Where to write rca_report.json and rca_report.md. Default rca/",
    )
    parser.add_argument("--step", type=int, default=STEP_SECONDS, help="Query step in seconds.")
    args = parser.parse_args()

    incident_path = os.path.abspath(args.incident)
    if not os.path.exists(incident_path):
        print(f"error: incident file not found: {incident_path}", file=sys.stderr)
        print("       run a chaos experiment first: ./chaos/chaos.sh errors 120", file=sys.stderr)
        return 1

    try:
        with open(incident_path) as handle:
            incident = json.load(handle)
    except json.JSONDecodeError as exc:
        print(f"error: {incident_path} is not valid JSON: {exc}", file=sys.stderr)
        return 1

    windows = incident.get("windows")
    if not windows or "query" not in windows:
        print("error: incident file has no windows.query, was it written by this chaos.sh?", file=sys.stderr)
        return 1

    q_start = windows["query"]["start_epoch"]
    q_end = windows["query"]["end_epoch"]

    print(f"incident : {incident.get('mode')} mode, {incident.get('started_at')} to {incident.get('ended_at')}")
    print(f"window   : {iso(q_start)} to {iso(q_end)} ({round(q_end - q_start)}s including baseline)")
    print(f"prometheus: {args.prometheus}")
    print()

    analyses = []
    raw_samples: dict = {}
    for signal in SIGNALS:
        try:
            samples = query_range(args.prometheus, signal["query"], q_start, q_end, args.step)
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

        raw_samples[signal["key"]] = samples
        analysis = analyse_signal(signal, samples, windows)
        analyses.append(analysis)

        status = "BREACHED" if analysis.get("breached") else ("no data" if not samples else "ok")
        print(
            f"  {signal['label']:20} {len(samples):4d} samples  "
            f"peak={fmt(analysis.get('peak'))!s:>10}  {status}"
        )

    ranking = rank_signals(analyses)
    trigger = infer_trigger(analyses, incident)
    remediation = correlate_remediation(incident, analyses, raw_samples)

    # Signals with no pre-injection samples have no baseline to compare against.
    # That is common for traffic derived signals when the system was idle before
    # the run. Say so rather than letting "n/a" look like a bug.
    no_baseline = [a["label"] for a in analyses if a["baseline"] is None and a["data_available"]]

    report = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "rca/rca.py",
        "analysis_method": "rule based threshold crossing and ordering, not machine learning",
        "data_source": {"prometheus": args.prometheus, "incident_file": incident_path},
        "disclaimer": (
            "Traffic in this window was generated by chaos/chaos.sh. These are "
            "simulated requests in a lab. No real users were affected."
        ),
        "incident": incident,
        "query_window": {
            "start_epoch": q_start,
            "end_epoch": q_end,
            "start": iso(q_start),
            "end": iso(q_end),
            "step_seconds": args.step,
        },
        "detection_rules": {
            "min_consecutive_samples": MIN_CONSECUTIVE,
            "min_sustained_seconds": MIN_CONSECUTIVE * args.step,
            "baseline_statistic": "median of pre-injection samples",
            "signals_without_baseline": no_baseline,
            "baseline_note": (
                "Signals with no pre-injection samples have no baseline. This is normal "
                "for traffic derived signals when the system was idle before the run: "
                "no requests means no series to measure."
            )
            if no_baseline
            else None,
        },
        "signals": analyses,
        "ranking": ranking,
        "trigger": trigger,
        "remediation": remediation,
    }

    os.makedirs(args.out_dir, exist_ok=True)
    json_path = os.path.join(args.out_dir, "rca_report.json")
    md_path = os.path.join(args.out_dir, "rca_report.md")

    with open(json_path, "w") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")

    with open(md_path, "w") as handle:
        handle.write(build_markdown(report))

    print()
    print(f"VERDICT  : {trigger['verdict']} (confidence {trigger['confidence']})")
    print(f"           {trigger['headline']}")
    print()
    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
