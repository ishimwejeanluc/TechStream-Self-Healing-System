"""TechStream demo web app.

Exposes Prometheus metrics on /metrics and two chaos endpoints used to inject
a failure that the self-healing loop is expected to detect and remediate.

Metric names and labels are fixed by the Grafana dashboard:
  http_request_duration_seconds  histogram, gives _bucket with the "le" label
  http_requests_total            counter with a numeric "status" label
"""

import multiprocessing
import os
import random
import threading
import time

from flask import Flask, g, jsonify, request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

APP_NAME = os.getenv("APP_NAME", "techstream-web")
BASE_LATENCY_MS = float(os.getenv("BASE_LATENCY_MS", "25"))
CPU_BURN_MAX_SECONDS = int(os.getenv("CPU_BURN_MAX_SECONDS", "300"))
CPU_BURN_MAX_WORKERS = int(os.getenv("CPU_BURN_MAX_WORKERS", "4"))

app = Flask(__name__)

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
    "Share of requests to normal endpoints currently forced to return 500",
)

CHAOS_CPU_WORKERS = Gauge(
    "chaos_cpu_workers_active",
    "Number of CPU burn worker processes currently running",
)

APP_INFO = Gauge("app_start_time_seconds", "Unix time the process started")
APP_INFO.set(time.time())

# Global chaos state. A restart clears it, which is what makes the
# automated "docker compose restart app" remediation visibly work.
_state_lock = threading.Lock()
_state = {"error_rate": 0.0}

_cpu_procs: list[multiprocessing.Process] = []
_cpu_lock = threading.Lock()


def _current_error_rate() -> float:
    with _state_lock:
        return _state["error_rate"]


def _set_error_rate(value: float) -> float:
    value = max(0.0, min(1.0, value))
    with _state_lock:
        _state["error_rate"] = value
    CHAOS_ERROR_RATE.set(value)
    return value


def _endpoint_label() -> str:
    # Use the route template, not the raw path, to keep label cardinality flat.
    return request.url_rule.rule if request.url_rule else "unmatched"


@app.before_request
def _start_timer() -> None:
    g.started_at = time.perf_counter()


@app.after_request
def _record_metrics(response: Response) -> Response:
    started_at = getattr(g, "started_at", None)
    if started_at is not None:
        elapsed = time.perf_counter() - started_at
        endpoint = _endpoint_label()
        REQUEST_DURATION.labels(request.method, endpoint).observe(elapsed)
        REQUESTS_TOTAL.labels(request.method, endpoint, str(response.status_code)).inc()
    return response


@app.errorhandler(Exception)
def _unhandled(exc: Exception):
    app.logger.exception("unhandled error: %s", exc)
    return jsonify({"app": APP_NAME, "error": "internal server error"}), 500


def _simulated_work() -> None:
    """Sleep for a lognormal-ish time so p50, p95 and p99 differ."""
    seconds = (BASE_LATENCY_MS / 1000.0) * random.lognormvariate(0.0, 0.45)
    time.sleep(min(seconds, 2.0))


@app.get("/")
def index():
    _simulated_work()
    if random.random() < _current_error_rate():
        return jsonify({"app": APP_NAME, "error": "injected failure"}), 500
    return jsonify({"app": APP_NAME, "status": "ok"}), 200


@app.get("/api/work")
def api_work():
    """Normal endpoint. Returns 200 and records request latency."""
    _simulated_work()
    if random.random() < _current_error_rate():
        return jsonify({"app": APP_NAME, "error": "injected failure"}), 500
    return jsonify({"app": APP_NAME, "result": random.randint(1, 1000)}), 200


@app.get("/healthz")
def healthz():
    return jsonify({"app": APP_NAME, "status": "healthy"}), 200


@app.get("/chaos/errors")
def chaos_errors():
    """Fail this request with probability ?rate= (default 1.0).

    Mode B of chaos.sh hits this at a steady rate to push the error ratio
    above 5 percent. Pass ?persist=true to also apply the same share to the
    normal endpoints until the process restarts.
    """
    try:
        rate = float(request.args.get("rate", "1.0"))
    except ValueError:
        return jsonify({"app": APP_NAME, "error": "rate must be a number"}), 400

    rate = max(0.0, min(1.0, rate))

    if request.args.get("persist", "").lower() in ("1", "true", "yes"):
        _set_error_rate(rate)

    _simulated_work()
    if random.random() < rate:
        return jsonify({"app": APP_NAME, "error": "injected 500", "rate": rate}), 500
    return jsonify({"app": APP_NAME, "status": "ok", "rate": rate}), 200


def _burn_cpu(deadline: float) -> None:
    total = 0
    while time.time() < deadline:
        total += sum(i * i for i in range(20000))


def _reap_cpu_workers() -> None:
    while True:
        time.sleep(1)
        with _cpu_lock:
            for proc in list(_cpu_procs):
                if not proc.is_alive():
                    proc.join(timeout=0)
                    _cpu_procs.remove(proc)
            CHAOS_CPU_WORKERS.set(len(_cpu_procs))


@app.get("/chaos/cpu")
def chaos_cpu():
    """Burn CPU for ?seconds= across ?workers= processes, then return."""
    try:
        seconds = int(request.args.get("seconds", "30"))
        workers = int(request.args.get("workers", "2"))
    except ValueError:
        return jsonify({"app": APP_NAME, "error": "seconds and workers must be integers"}), 400

    seconds = max(1, min(seconds, CPU_BURN_MAX_SECONDS))
    workers = max(1, min(workers, CPU_BURN_MAX_WORKERS))
    deadline = time.time() + seconds

    started = []
    with _cpu_lock:
        for _ in range(workers):
            proc = multiprocessing.Process(target=_burn_cpu, args=(deadline,), daemon=True)
            proc.start()
            _cpu_procs.append(proc)
            started.append(proc.pid)
        CHAOS_CPU_WORKERS.set(len(_cpu_procs))

    return jsonify(
        {"app": APP_NAME, "burning": True, "seconds": seconds, "workers": workers, "pids": started}
    ), 202


@app.get("/chaos/reset")
def chaos_reset():
    _set_error_rate(0.0)
    return jsonify({"app": APP_NAME, "error_rate": 0.0}), 200


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


CHAOS_ERROR_RATE.set(0.0)
CHAOS_CPU_WORKERS.set(0)
threading.Thread(target=_reap_cpu_workers, daemon=True).start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
