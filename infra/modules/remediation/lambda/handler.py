"""Alertmanager webhook receiver that remediates TechStream automatically.

Flow:
  Prometheus fires HighErrorRate
    -> Alertmanager posts the webhook payload to this Function URL
    -> this handler validates the shared token
    -> confirms at least one alert is actually firing, not resolved
    -> calls SSM SendCommand against the custom restart document
    -> logs the command ID and returns 200

The Function URL uses auth NONE because Alertmanager cannot sign SigV4
requests. The ?token= shared secret is therefore the only thing gating
remediation, so treat it like a password.
"""

import hmac
import json
import logging
import os
import time

import boto3
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))

INSTANCE_ID = os.environ["INSTANCE_ID"]
SSM_DOCUMENT_NAME = os.environ["SSM_DOCUMENT_NAME"]
WEBHOOK_TOKEN = os.getenv("WEBHOOK_TOKEN", "")
EXPECTED_ALERTNAME = os.getenv("EXPECTED_ALERTNAME", "HighErrorRate")

ENABLE_SCALE_OUT = os.getenv("ENABLE_SCALE_OUT", "false").lower() == "true"
ASG_NAME = os.getenv("ASG_NAME", "")
SCALE_OUT_INCREMENT = int(os.getenv("SCALE_OUT_INCREMENT", "1"))

ENABLE_EVENTBRIDGE_AUDIT = os.getenv("ENABLE_EVENTBRIDGE_AUDIT", "false").lower() == "true"
EVENT_BUS_NAME = os.getenv("EVENT_BUS_NAME", "default")

# Best-effort restart throttle. Alertmanager repeat_interval is the real guard.
# This only survives while the execution environment stays warm, so it reduces
# restart storms rather than preventing them outright.
MIN_SECONDS_BETWEEN_ACTIONS = int(os.getenv("MIN_SECONDS_BETWEEN_ACTIONS", "120"))
_last_action_at = 0.0

_boto_config = Config(retries={"max_attempts": 3, "mode": "standard"})
ssm = boto3.client("ssm", config=_boto_config)


def _response(status: int, payload: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _token_ok(event: dict) -> bool:
    if not WEBHOOK_TOKEN:
        LOG.warning("WEBHOOK_TOKEN is empty, accepting the request without a token check")
        return True

    params = event.get("queryStringParameters") or {}
    supplied = params.get("token", "")
    if not supplied:
        header_token = (event.get("headers") or {}).get("x-remediation-token", "")
        supplied = header_token

    return hmac.compare_digest(str(supplied), WEBHOOK_TOKEN)


def _parse_body(event: dict) -> dict:
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64

        body = base64.b64decode(body).decode("utf-8")
    return json.loads(body)


def _firing_alerts(payload: dict) -> list:
    """Return only alerts whose own status is firing.

    The top level "status" field can say firing while an individual alert in
    the batch is resolved, so filter per alert rather than trusting the group.
    """
    alerts = payload.get("alerts") or []
    return [a for a in alerts if str(a.get("status", "")).lower() == "firing"]


def _describe(alert: dict) -> dict:
    labels = alert.get("labels") or {}
    annotations = alert.get("annotations") or {}
    return {
        "alertname": labels.get("alertname"),
        "app": labels.get("app"),
        "severity": labels.get("severity"),
        "ratio": annotations.get("ratio") or annotations.get("value"),
        "summary": annotations.get("summary"),
        "startsAt": alert.get("startsAt"),
    }


def _restart_via_ssm(alerts: list) -> dict:
    comment = f"Auto-remediation for {EXPECTED_ALERTNAME} ({len(alerts)} firing)"[:100]

    result = ssm.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName=SSM_DOCUMENT_NAME,
        Comment=comment,
        TimeoutSeconds=600,
    )
    command_id = result["Command"]["CommandId"]

    LOG.info(
        "sent SSM command: command_id=%s document=%s instance=%s",
        command_id,
        SSM_DOCUMENT_NAME,
        INSTANCE_ID,
    )
    return {"action": "restart", "command_id": command_id, "instance_id": INSTANCE_ID}


def _scale_out() -> dict:
    """Documented alternative, enabled with enable_scale_out = true.

    Restart is the default because the failure this lab injects is a bad
    process, and a restart clears it in seconds. Scale-out adds capacity, which
    only helps when the cause is genuine saturation, and it does nothing for a
    process that is returning 500s on every instance.
    """
    autoscaling = boto3.client("autoscaling", config=_boto_config)
    groups = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])

    if not groups["AutoScalingGroups"]:
        raise RuntimeError(f"Auto Scaling group not found: {ASG_NAME}")

    group = groups["AutoScalingGroups"][0]
    current = group["DesiredCapacity"]
    target = min(current + SCALE_OUT_INCREMENT, group["MaxSize"])

    if target == current:
        LOG.warning("already at MaxSize=%s, not scaling out", group["MaxSize"])
        return {"action": "scale_out", "skipped": True, "desired_capacity": current}

    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=target,
        HonorCooldown=True,
    )
    LOG.info("scaled %s from %s to %s", ASG_NAME, current, target)
    return {"action": "scale_out", "from": current, "to": target, "asg": ASG_NAME}


def _publish_audit_event(outcome: dict, alerts: list) -> None:
    """Off the critical path. Failures here never fail remediation."""
    try:
        events = boto3.client("events", config=_boto_config)
        events.put_events(
            Entries=[
                {
                    "EventBusName": EVENT_BUS_NAME,
                    "Source": "techstream.selfhealing",
                    "DetailType": "RemediationPerformed",
                    "Detail": json.dumps(
                        {"outcome": outcome, "alerts": [_describe(a) for a in alerts]}
                    ),
                }
            ]
        )
        LOG.info("published audit event to bus %s", EVENT_BUS_NAME)
    except Exception as exc:  # noqa: BLE001 - audit must never break remediation
        LOG.warning("audit event publish failed, continuing: %s", exc)


def lambda_handler(event, context):
    global _last_action_at

    if not _token_ok(event):
        LOG.warning("rejected a request with a bad or missing token")
        return _response(403, {"error": "forbidden"})

    try:
        payload = _parse_body(event)
    except (ValueError, TypeError) as exc:
        LOG.error("could not parse the request body: %s", exc)
        return _response(400, {"error": "invalid JSON body"})

    group_status = payload.get("status")
    alerts = _firing_alerts(payload)

    LOG.info(
        "received webhook: group_status=%s alerts=%s firing=%s details=%s",
        group_status,
        len(payload.get("alerts") or []),
        len(alerts),
        json.dumps([_describe(a) for a in (payload.get("alerts") or [])]),
    )

    if not alerts:
        # A resolved notification is the normal end of an incident. Nothing to do.
        return _response(200, {"remediated": False, "reason": "no firing alerts in payload"})

    matched = [a for a in alerts if (a.get("labels") or {}).get("alertname") == EXPECTED_ALERTNAME]
    if not matched:
        names = sorted({(a.get("labels") or {}).get("alertname") for a in alerts})
        LOG.info("no %s in this batch, saw %s", EXPECTED_ALERTNAME, names)
        return _response(200, {"remediated": False, "reason": f"no {EXPECTED_ALERTNAME} alert"})

    since_last = time.time() - _last_action_at
    if _last_action_at and since_last < MIN_SECONDS_BETWEEN_ACTIONS:
        LOG.warning("throttled: last action was %.0fs ago", since_last)
        return _response(
            200,
            {
                "remediated": False,
                "reason": "throttled",
                "seconds_since_last_action": round(since_last),
            },
        )

    try:
        outcome = _scale_out() if ENABLE_SCALE_OUT else _restart_via_ssm(matched)
    except Exception as exc:  # noqa: BLE001 - surface the failure to Alertmanager
        LOG.exception("remediation failed")
        return _response(500, {"remediated": False, "error": str(exc)})

    _last_action_at = time.time()

    if ENABLE_EVENTBRIDGE_AUDIT:
        _publish_audit_event(outcome, matched)

    return _response(200, {"remediated": True, **outcome})
