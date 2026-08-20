#!/usr/bin/env python3
"""Turn the deterministic RCA plus the Grafana ML signals into prose.

This is the piece that produces what DevOps Guru calls an "insight": a written
explanation and prioritised recommendations, rather than a number.

Division of labour, deliberately:

  rca.py      measures and decides.   Thresholds, ordering, verdict. No model.
  narrate.py  explains.               Claude writes prose from those facts.

rca.py stays standard-library only so it always works offline. This script is
the only part that needs a network and an API key, and it is optional.

The model is given facts and told not to invent numbers. The deterministic
verdict is carried into the output next to the prose, so a reader can check the
narrative against the data rather than trusting it.

Requires:
  pip install anthropic
  ANTHROPIC_API_KEY=...     (or: ant auth login)

Usage:
  python3 rca/narrate.py
  python3 rca/narrate.py --no-ml          # skip the Grafana Cloud lookup
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODEL = "claude-opus-5"

# The ML output metrics, from the grafanacloud-ml-metrics datasource. These are
# the model's findings: what it expected, what happened, and whether it called it
# anomalous.
ML_QUERIES = {
    "error_ratio_actual": "techstream_error_ratio:actual",
    "error_ratio_predicted": "techstream_error_ratio:predicted",
    "error_ratio_anomalous": "techstream_error_ratio:anomalous",
    "latency_p95_actual": "techstream_latency_p95:actual",
    "latency_p95_anomalous": "techstream_latency_p95:anomalous",
    "request_rate_actual": "techstream_request_rate:actual",
    "request_rate_anomalous": "techstream_request_rate:anomalous",
    "container_cpu_outliers": "techstream_container_cpu_outliers:outliers",
    "container_cpu_outlier_scores": "techstream_container_cpu_outliers:outlier_scores",
}


def read_tfvar(name: str) -> str:
    """Pull a value out of infra/grafana-ml/terraform.tfvars."""
    path = REPO / "infra" / "grafana-ml" / "terraform.tfvars"
    if not path.exists():
        return ""
    for line in path.read_text().splitlines():
        if line.strip().startswith(name):
            return line.split("=", 1)[1].strip().strip('"')
    return ""


def fetch_ml_signals(window: dict) -> dict:
    """Query the ML datasource over the incident window.

    Returns a compact summary per signal rather than raw series. The model does
    not need thousands of datapoints, it needs the shape: min, max, mean, and
    whether the anomaly flag was ever raised.
    """
    url = os.getenv("GRAFANA_URL") or read_tfvar("grafana_url")
    token = os.getenv("GRAFANA_TOKEN") or read_tfvar("grafana_auth")
    if not url or not token:
        return {"available": False, "reason": "no grafana_url or grafana_auth found"}

    base = f"{url.rstrip('/')}/api/datasources/proxy/uid/grafanacloud-ml-metrics/api/v1/query_range"
    out: dict = {"available": True, "datasource": "grafanacloud-ml-metrics", "signals": {}}

    for key, expr in ML_QUERIES.items():
        params = urllib.parse.urlencode({
            "query": expr,
            "start": f"{window['start_epoch']:.0f}",
            "end": f"{window['end_epoch']:.0f}",
            "step": "60",
        })
        req = urllib.request.Request(
            f"{base}?{params}", headers={"Authorization": f"Bearer {token}"}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.load(resp)
        except Exception as exc:  # noqa: BLE001 - a missing signal is data, not a crash
            out["signals"][key] = {"error": str(exc)}
            continue

        series = body.get("data", {}).get("result", [])
        if not series:
            out["signals"][key] = {"present": False}
            continue

        summary = []
        for s in series[:6]:
            vals = []
            for _, raw in s["values"]:
                try:
                    v = float(raw)
                except (TypeError, ValueError):
                    continue
                if v == v and abs(v) != float("inf"):  # drop NaN and Inf
                    vals.append(v)
            if not vals:
                continue
            summary.append({
                "labels": s.get("metric", {}),
                "points": len(vals),
                "min": round(min(vals), 5),
                "max": round(max(vals), 5),
                "mean": round(sum(vals) / len(vals), 5),
                "ever_nonzero": any(v != 0 for v in vals),
            })
        out["signals"][key] = {"present": True, "expr": expr, "series": summary}

    return out


SYSTEM = """You are writing the narrative section of a production incident report.

You are given machine-produced facts from three sources:
  1. incident: the injected fault and its exact time window
  2. deterministic_rca: a rule-based analysis with thresholds, breach ordering
     and a verdict. This is not a model, it is arithmetic.
  3. ml_signals: output from Grafana Cloud Machine Learning. For each signal it
     reports what the model predicted, what actually happened, and whether the
     model flagged it as anomalous.

Hard rules:

- Use ONLY the numbers present in the input. Never invent, estimate or round to
  a nicer figure. If something is absent, say it is absent.
- Do not contradict deterministic_rca.verdict. If the ML signals point somewhere
  else, say so explicitly and explain the disagreement rather than picking a side
  silently.
- This is a lab. Traffic is generated by a chaos script and the fault was
  injected deliberately. Never write as if real users were affected.
- Distinguish measured from inferred. If recovery was inferred rather than read
  directly, say so.
- Plain, direct writing. No em-dashes. No filler like "it is important to note".

Write GitHub-flavoured Markdown with exactly these sections:

## What happened
Two or three sentences. Lead with the conclusion.

## Evidence
A table: Signal | Expected | Observed | Model flagged anomaly? | Source.
"Source" is either "threshold rule" or "ML forecast".

## Why this happened
The mechanism. Name what led and what followed, with the timings you were given.

## Recommendations
Numbered, ordered by value. Each one: the action, then why it follows from the
evidence above. Distinguish what fixes this incident from what prevents the next.
If the appropriate action is to change nothing, say that.

## What the data cannot tell us
The honest limits. Missing signals, inferred conclusions, thresholds that were
chosen rather than measured, models trained on little history."""


def build_payload(incident: dict, rca: dict, ml: dict) -> str:
    # Trim the RCA down to the fields that matter, so the model is not wading
    # through raw sample arrays.
    slim = {
        "verdict": rca.get("trigger", {}),
        "signals": [
            {
                k: s.get(k)
                for k in (
                    "label", "unit", "kind", "threshold", "baseline", "peak",
                    "breached", "first_breach_at", "recovered_at",
                    "peak_over_threshold", "baseline_contaminated",
                )
            }
            for s in rca.get("signals", [])
        ],
        "ranking": rca.get("ranking", {}),
        "remediation": rca.get("remediation", {}),
        "detection_rules": rca.get("detection_rules", {}),
    }
    return json.dumps(
        {"incident": incident, "deterministic_rca": slim, "ml_signals": ml},
        indent=2,
        default=str,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--incident", default=str(REPO / "chaos" / "incident.json"))
    ap.add_argument("--rca", default=str(REPO / "rca" / "rca_report.json"))
    ap.add_argument("--out", default=str(REPO / "rca" / "rca_narrative.md"))
    ap.add_argument("--no-ml", action="store_true", help="Skip the Grafana Cloud lookup.")
    ap.add_argument("--model", default=MODEL)
    args = ap.parse_args()

    try:
        import anthropic
    except ImportError:
        print("error: the anthropic SDK is not installed.", file=sys.stderr)
        print("       pip install anthropic", file=sys.stderr)
        return 1

    for path in (args.incident, args.rca):
        if not Path(path).exists():
            print(f"error: {path} not found.", file=sys.stderr)
            print("       run a chaos experiment and then: make rca", file=sys.stderr)
            return 1

    incident = json.loads(Path(args.incident).read_text())
    rca = json.loads(Path(args.rca).read_text())

    if args.no_ml:
        ml = {"available": False, "reason": "skipped with --no-ml"}
    else:
        print("querying Grafana Cloud ML metrics over the incident window...")
        ml = fetch_ml_signals(rca["query_window"])
        if ml.get("available"):
            found = sum(1 for v in ml["signals"].values() if v.get("present"))
            print(f"  {found}/{len(ML_QUERIES)} ML signals had data")
        else:
            print(f"  skipped: {ml.get('reason')}")

    payload = build_payload(incident, rca, ml)
    print(f"sending {len(payload)} chars to {args.model}...")

    client = anthropic.Anthropic()

    try:
        # Streamed because the report can be long, which would otherwise risk an
        # HTTP timeout. get_final_message() gives the assembled response.
        with client.messages.stream(
            model=args.model,
            max_tokens=64000,
            system=SYSTEM,
            thinking={"type": "adaptive"},
            output_config={"effort": "high"},
            messages=[{
                "role": "user",
                "content": (
                    "Write the incident narrative from these facts.\n\n"
                    f"```json\n{payload}\n```"
                ),
            }],
        ) as stream:
            response = stream.get_final_message()
    except anthropic.AuthenticationError:
        print("error: no valid credentials. Set ANTHROPIC_API_KEY or run: ant auth login",
              file=sys.stderr)
        return 1
    except anthropic.RateLimitError as exc:
        retry = exc.response.headers.get("retry-after", "60")
        print(f"error: rate limited, retry after {retry}s", file=sys.stderr)
        return 1
    except anthropic.APIStatusError as exc:
        print(f"error: API returned {exc.status_code}: {exc.message}", file=sys.stderr)
        return 1
    except anthropic.APIConnectionError:
        print("error: could not reach the API. Check the network.", file=sys.stderr)
        return 1

    if response.stop_reason == "refusal":
        detail = getattr(response, "stop_details", None)
        print(f"error: the model declined. category={getattr(detail, 'category', None)}",
              file=sys.stderr)
        return 1

    narrative = "\n".join(b.text for b in response.content if b.type == "text").strip()
    if not narrative:
        print("error: the model returned no text", file=sys.stderr)
        return 1

    verdict = rca.get("trigger", {})
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    header = f"""# Incident narrative

Generated {generated} by `rca/narrate.py` using `{response.model}`.

> **This section was written by a language model** from the numbers produced by
> `rca.py` and by the Grafana Cloud ML jobs. It contains no measurements of its
> own. The deterministic verdict it was given is repeated below so the prose can
> be checked against it.
>
> Traffic in this window was generated by `chaos/chaos.sh`. These are simulated
> requests in a lab. No real users were affected.

**Deterministic verdict (rule-based, not the model's opinion)**

| Field | Value |
|---|---|
| Verdict | `{verdict.get('verdict')}` |
| Confidence | {verdict.get('confidence')} |
| Recommended remediation | `{verdict.get('recommended_remediation')}` |

**ML signals available:** {"yes" if ml.get("available") else "no, " + str(ml.get("reason"))}

---

"""

    footer = f"""

---

## Provenance

| Item | Value |
|---|---|
| Model | `{response.model}` |
| Input tokens | {response.usage.input_tokens} |
| Output tokens | {response.usage.output_tokens} |
| Request ID | `{response._request_id}` |
| Sources | `chaos/incident.json`, `rca/rca_report.json`, `grafanacloud-ml-metrics` |

`rca.py` produced the measurements and the verdict without any model. This file
is the narrative layer on top. If the two ever disagree, trust `rca.py` and treat
this as a drafting error.
"""

    Path(args.out).write_text(header + narrative + footer)
    print()
    print(f"wrote {args.out}")
    print(f"  model={response.model} in={response.usage.input_tokens} out={response.usage.output_tokens}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
