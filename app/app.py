"""TechStream demo web app.

Serves normal traffic, exposes Prometheus metrics, and provides two chaos
endpoints used to inject the incident the self-healing loop reacts to.

Metric names and labels are fixed by the Grafana dashboard and the alert rule.
Do not rename them:

    http_requests_total{method,endpoint,status}   counter, status is numeric
    http_request_duration_seconds                 histogram, gives _bucket{le}

Chaos state is held in memory on purpose. Restarting the container clears it,
which is exactly what makes the automated SSM restart visibly resolve the alert.
"""

import os
import random
import shutil
import subprocess
import threading
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

APP_NAME = os.getenv("APP_NAME", "techstream-web")
PORT = int(os.getenv("PORT", "8080"))
# Latency is split between real CPU work and a sleep. The CPU part has to
# dominate enough that saturating the cores actually slows requests down,
# otherwise CPU chaos produces no latency effect and the RCA can never observe
# CPU leading latency.
#
# Measured in this image: 25000 iterations is about 10ms of CPU. Combined with a
# 15ms sleep that gives a baseline p50 near 25ms, and under CPU contention the
# 10ms stretches while the sleep does not.
#
# An earlier version used 1500 iterations, which measured 0.7ms. That was far
# too little: at 4x core oversubscription p95 latency only reached 0.185s,
# because a sleep takes its wall clock time regardless of CPU pressure.
BASE_LATENCY_MS = float(os.getenv("BASE_LATENCY_MS", "15"))
CPU_WORK_ITERATIONS = int(os.getenv("CPU_WORK_ITERATIONS", "25000"))
MAX_CPU_SECONDS = int(os.getenv("MAX_CPU_SECONDS", "600"))
MAX_CPU_WORKERS = int(os.getenv("MAX_CPU_WORKERS", "8"))

app = Flask(__name__)

# Buckets are spread around the expected p50 of about 25ms and up past a second,
# so p50, p95 and p99 stay distinguishable when latency degrades.
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0),
)

REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests by method, endpoint and numeric status code",
    ["method", "endpoint", "status"],
)

CHAOS_ERROR_RATE = Gauge(
    "chaos_error_rate",
    "Share of requests to / and /work currently forced to return 500",
)

# Counts stress-ng invocations, not worker processes. One POST /chaos/cpu with
# cpus=2 is a single run that spawns 2 workers, so this reads 1. The requested
# core count is tracked separately below.
CHAOS_CPU_RUNS = Gauge(
    "chaos_cpu_runs_active",
    "stress-ng invocations currently running",
)

CHAOS_CPU_CORES = Gauge(
    "chaos_cpu_cores_requested",
    "Total CPU cores stress-ng was asked to saturate across active runs",
)

_STARTED_AT = time.time()

APP_START_TIME = Gauge(
    "app_start_time_seconds",
    "Unix time this process started. Steps up when the container is restarted.",
)
APP_START_TIME.set(_STARTED_AT)

# Endpoints excluded from request metrics.
#
# /metrics is scraped every 15s and /healthz is polled by the container health
# check. Both are infrastructure traffic, not application traffic. Counting them
# would pad the denominator of the error ratio and make the 5 percent threshold
# depend on scrape interval rather than on real failures.
UNMEASURED_ENDPOINTS = {"/metrics", "/healthz"}

_state_lock = threading.Lock()
_error_rate = 0.0

_cpu_lock = threading.Lock()
# Each entry is (process, cores_requested), so both gauges can be derived.
_cpu_runs: list[tuple[subprocess.Popen, int]] = []

STRESS_NG = shutil.which("stress-ng")


def _get_error_rate() -> float:
    with _state_lock:
        return _error_rate


def _set_error_rate(value: float) -> float:
    global _error_rate
    clamped = max(0.0, min(1.0, value))
    with _state_lock:
        _error_rate = clamped
    CHAOS_ERROR_RATE.set(clamped)
    return clamped


def _endpoint_label() -> str:
    # The route template, not the raw path, so label cardinality stays flat.
    return request.url_rule.rule if request.url_rule else "unmatched"


@app.before_request
def _start_timer() -> None:
    g.started_at = time.perf_counter()


@app.after_request
def _record_metrics(response: Response) -> Response:
    started_at = getattr(g, "started_at", None)
    endpoint = _endpoint_label()

    if started_at is not None and endpoint not in UNMEASURED_ENDPOINTS:
        REQUEST_DURATION.labels(request.method, endpoint).observe(
            time.perf_counter() - started_at
        )
        REQUESTS_TOTAL.labels(request.method, endpoint, str(response.status_code)).inc()

    return response


@app.errorhandler(Exception)
def _unhandled(exc: Exception):
    app.logger.exception("unhandled error: %s", exc)
    return jsonify({"app": APP_NAME, "error": "internal server error"}), 500


def _do_work() -> None:
    """Simulate a request that does some real work.

    Two parts on purpose. The busy loop consumes real CPU, so when stress-ng
    saturates the cores this request genuinely slows down. That causal link is
    what makes the RCA in Step 6 able to observe CPU rising before latency. The
    sleep adds a lognormal spread so p50, p95 and p99 stay distinguishable
    instead of collapsing onto one line.

    The CPU part has to be the larger of the two. A sleep-dominated request
    barely responds to CPU pressure, which breaks the causal chain the whole lab
    is built to demonstrate.
    """
    total = 0
    for i in range(CPU_WORK_ITERATIONS):
        total += i * i

    seconds = (BASE_LATENCY_MS / 1000.0) * random.lognormvariate(0.0, 0.45)
    time.sleep(min(seconds, 2.0))


def _maybe_fail():
    """Return a 500 response when the injected error rate says so."""
    if random.random() < _get_error_rate():
        return jsonify({"app": APP_NAME, "error": "injected failure"}), 500
    return None


@app.get("/")
def index():
    _do_work()
    failure = _maybe_fail()
    if failure:
        return failure
    return jsonify({"app": APP_NAME, "status": "ok"}), 200


@app.get("/work")
def work():
    _do_work()
    failure = _maybe_fail()
    if failure:
        return failure
    return jsonify({"app": APP_NAME, "result": random.randint(1, 1000)}), 200


@app.get("/healthz")
def healthz():
    """Never subject to the injected error rate.

    A health check that lies when chaos is active would make the container
    unhealthy and let Docker restart it, which would hide whether the SSM
    remediation path actually did the work.
    """
    return jsonify(
        {
            "app": APP_NAME,
            "status": "healthy",
            "error_rate": _get_error_rate(),
            "cpu_runs": len(_cpu_runs),
            "cpu_cores_requested": sum(cores for _, cores in _cpu_runs),
            "uptime_seconds": round(time.time() - _STARTED_AT, 1),
        }
    ), 200


@app.post("/chaos/errors")
def chaos_errors():
    """Set the share of requests to / and /work that return 500.

    POST /chaos/errors?rate=0.4
    Set rate=0 to clear it. Restarting the container also clears it.
    """
    raw = request.args.get("rate")
    if raw is None and request.is_json:
        raw = str((request.get_json(silent=True) or {}).get("rate", ""))

    try:
        rate = float(raw)
    except (TypeError, ValueError):
        return jsonify({"app": APP_NAME, "error": "rate must be a number between 0 and 1"}), 400

    applied = _set_error_rate(rate)
    app.logger.warning("chaos: error rate set to %.2f", applied)
    return jsonify({"app": APP_NAME, "error_rate": applied}), 200


def _publish_cpu_gauges() -> None:
    """Caller must hold _cpu_lock."""
    CHAOS_CPU_RUNS.set(len(_cpu_runs))
    CHAOS_CPU_CORES.set(sum(cores for _, cores in _cpu_runs))


def _reap_cpu_runs() -> None:
    """Clear finished stress-ng runs so the gauges do not drift upward.

    stress-ng exits on its own after its --timeout, and poll() reaps it so it
    does not linger as a zombie.
    """
    while True:
        time.sleep(2)
        with _cpu_lock:
            for entry in list(_cpu_runs):
                if entry[0].poll() is not None:
                    _cpu_runs.remove(entry)
            _publish_cpu_gauges()


@app.post("/chaos/cpu")
def chaos_cpu():
    """Saturate CPU cores with stress-ng in the background.

    POST /chaos/cpu?seconds=45&cpus=2
    Returns immediately with 202. stress-ng exits on its own after the timeout.
    """
    if not STRESS_NG:
        return jsonify({"app": APP_NAME, "error": "stress-ng is not installed in this image"}), 501

    try:
        seconds = int(request.args.get("seconds", "45"))
        cpus = int(request.args.get("cpus", "2"))
    except ValueError:
        return jsonify({"app": APP_NAME, "error": "seconds and cpus must be integers"}), 400

    seconds = max(1, min(seconds, MAX_CPU_SECONDS))
    cpus = max(1, min(cpus, MAX_CPU_WORKERS))

    proc = subprocess.Popen(
        [STRESS_NG, "--cpu", str(cpus), "--timeout", f"{seconds}s", "--metrics-brief"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    with _cpu_lock:
        _cpu_runs.append((proc, cpus))
        _publish_cpu_gauges()

    app.logger.warning("chaos: stress-ng pid=%s cpus=%s seconds=%s", proc.pid, cpus, seconds)
    return jsonify(
        {"app": APP_NAME, "burning": True, "pid": proc.pid, "cpus": cpus, "seconds": seconds}
    ), 202


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


CHAOS_ERROR_RATE.set(0.0)
CHAOS_CPU_RUNS.set(0)
CHAOS_CPU_CORES.set(0)
threading.Thread(target=_reap_cpu_runs, daemon=True).start()


if __name__ == "__main__":
    # Development only. Production entrypoint is gunicorn, see the Dockerfile.
    app.run(host="0.0.0.0", port=PORT)
