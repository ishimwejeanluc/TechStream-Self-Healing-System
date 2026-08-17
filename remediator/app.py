"""Local stand-in for the remediation Lambda.

Purpose: verify the self-healing loop end to end without AWS. It accepts the
same Alertmanager webhook payload, applies the same checks in the same order,
and performs the same logical action. The only difference is the mechanism:

    deployed path:  Alertmanager -> Lambda Function URL -> SSM SendCommand -> docker compose restart app
    local path:     Alertmanager -> this service        -> Docker API       -> restart techstream-app

The decision logic is deliberately identical to
infra/modules/remediation/lambda/handler.py, so a loop proven here is the same
loop that runs on EC2. If you change one, change the other.

SECURITY: this container mounts the Docker socket, which is equivalent to root
on the host. That is why it sits behind a compose profile and is not part of the
default stack. It exists for local verification only. Never run it on the EC2
instance, where the Lambda plus SSM path provides the same outcome with a scoped
IAM policy instead. If you do need something like it in a shared environment,
put a socket proxy in front and allow only the container restart endpoint.
"""

import hmac
import json
import logging
import os
import socket
import sys
import threading
import time
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)sZ %(levelname)s %(message)s",
)
LOG = logging.getLogger("remediator")
logging.Formatter.converter = time.gmtime

LISTEN_PORT = int(os.getenv("LISTEN_PORT", "8000"))
WEBHOOK_TOKEN = os.getenv("WEBHOOK_TOKEN", "")
TARGET_CONTAINER = os.getenv("TARGET_CONTAINER", "techstream-app")
EXPECTED_ALERTNAME = os.getenv("EXPECTED_ALERTNAME", "HighErrorRate")
DOCKER_SOCKET = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")
RESTART_TIMEOUT = int(os.getenv("RESTART_TIMEOUT", "10"))

# Same best-effort throttle as the Lambda. Alertmanager repeat_interval is the
# real guard against restart storms.
MIN_SECONDS_BETWEEN_ACTIONS = int(os.getenv("MIN_SECONDS_BETWEEN_ACTIONS", "120"))

_state_lock = threading.Lock()
_last_action_at = 0.0
_action_count = 0


class UnixHTTPConnection(HTTPConnection):
    """Minimal HTTP over a unix socket, so the Docker API needs no dependencies."""

    def __init__(self, socket_path: str, timeout: int = 30):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def restart_container(name: str) -> dict:
    """POST /containers/{name}/restart against the Docker API."""
    conn = UnixHTTPConnection(DOCKER_SOCKET, timeout=60)
    path = f"/v1.43/containers/{name}/restart?t={RESTART_TIMEOUT}"
    try:
        conn.request("POST", path)
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", "replace")
    finally:
        conn.close()

    if resp.status not in (204, 304):
        raise RuntimeError(f"docker restart failed: HTTP {resp.status} {body}")

    return {"action": "restart", "container": name, "docker_status": resp.status}


def token_ok(query: dict, headers) -> bool:
    if not WEBHOOK_TOKEN:
        LOG.warning("WEBHOOK_TOKEN is empty, accepting without a token check")
        return True

    supplied = (query.get("token") or [""])[0]
    if not supplied:
        supplied = headers.get("x-remediation-token", "")

    return hmac.compare_digest(str(supplied), WEBHOOK_TOKEN)


def firing_alerts(payload: dict) -> list:
    """Only alerts whose own status is firing.

    The batch level "status" can read firing while an individual alert inside it
    has already resolved, so filter per alert rather than trusting the group.
    """
    return [
        a
        for a in (payload.get("alerts") or [])
        if str(a.get("status", "")).lower() == "firing"
    ]


def describe(alert: dict) -> dict:
    labels = alert.get("labels") or {}
    annotations = alert.get("annotations") or {}
    return {
        "alertname": labels.get("alertname"),
        "app": labels.get("app"),
        "severity": labels.get("severity"),
        "ratio": annotations.get("ratio"),
        "startsAt": alert.get("startsAt"),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "techstream-remediator/1.0"

    def log_message(self, fmt, *args):  # noqa: A003 - quieter default access log
        LOG.debug("%s - %s", self.address_string(), fmt % args)

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if urlparse(self.path).path in ("/healthz", "/"):
            with _state_lock:
                count = _action_count
            self._send(200, {"status": "healthy", "restarts_performed": count})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        global _last_action_at, _action_count

        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if not token_ok(query, self.headers):
            LOG.warning("rejected a request with a bad or missing token")
            self._send(403, {"error": "forbidden"})
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError) as exc:
            LOG.error("could not parse the request body: %s", exc)
            self._send(400, {"error": "invalid JSON body"})
            return

        alerts = firing_alerts(payload)
        LOG.info(
            "webhook received: group_status=%s alerts=%s firing=%s details=%s",
            payload.get("status"),
            len(payload.get("alerts") or []),
            len(alerts),
            json.dumps([describe(a) for a in (payload.get("alerts") or [])]),
        )

        if not alerts:
            # A resolved notification is the normal end of an incident.
            self._send(200, {"remediated": False, "reason": "no firing alerts in payload"})
            return

        matched = [
            a for a in alerts if (a.get("labels") or {}).get("alertname") == EXPECTED_ALERTNAME
        ]
        if not matched:
            names = sorted({(a.get("labels") or {}).get("alertname") for a in alerts})
            LOG.info("no %s in this batch, saw %s", EXPECTED_ALERTNAME, names)
            self._send(200, {"remediated": False, "reason": f"no {EXPECTED_ALERTNAME} alert"})
            return

        with _state_lock:
            since_last = time.time() - _last_action_at
            throttled = _last_action_at and since_last < MIN_SECONDS_BETWEEN_ACTIONS

        if throttled:
            LOG.warning("throttled: last action was %.0fs ago", since_last)
            self._send(
                200,
                {
                    "remediated": False,
                    "reason": "throttled",
                    "seconds_since_last_action": round(since_last),
                },
            )
            return

        ratios = [describe(a).get("ratio") for a in matched]
        LOG.warning(
            "REMEDIATING: restarting %s because %s is firing (ratio=%s)",
            TARGET_CONTAINER,
            EXPECTED_ALERTNAME,
            ratios,
        )

        try:
            outcome = restart_container(TARGET_CONTAINER)
        except Exception as exc:  # noqa: BLE001 - surface it to Alertmanager
            LOG.exception("remediation failed")
            self._send(500, {"remediated": False, "error": str(exc)})
            return

        with _state_lock:
            _last_action_at = time.time()
            _action_count += 1
            count = _action_count

        LOG.warning(
            "RESTART COMPLETE: container=%s docker_status=%s restarts_performed=%s",
            outcome["container"],
            outcome["docker_status"],
            count,
        )
        self._send(200, {"remediated": True, "restarts_performed": count, **outcome})


def main() -> None:
    if not os.path.exists(DOCKER_SOCKET):
        LOG.error("Docker socket not found at %s, cannot restart anything", DOCKER_SOCKET)
        sys.exit(1)

    LOG.info(
        "listening on :%s target=%s alertname=%s throttle=%ss token=%s",
        LISTEN_PORT,
        TARGET_CONTAINER,
        EXPECTED_ALERTNAME,
        MIN_SECONDS_BETWEEN_ACTIONS,
        "set" if WEBHOOK_TOKEN else "NOT SET",
    )
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
