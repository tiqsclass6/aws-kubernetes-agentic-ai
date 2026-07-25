from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import uuid
from typing import Any

from flask import Flask, jsonify, request
from google.cloud import pubsub_v1

app = Flask(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]

TARGET_NAMESPACE = os.environ.get(
    "TARGET_NAMESPACE",
    "app01",
)

GUARDIAN_AUDIT_TOPIC = os.environ.get(
    "GUARDIAN_AUDIT_TOPIC",
    "guardian-audit",
)

SECURITY_EVENTS_TOPIC = os.environ.get(
    "SECURITY_EVENTS_TOPIC",
    "raw-security-events",
)

ALLOWED_CLIENT_DN_FRAGMENTS = {
    item.strip()
    for item in os.environ.get(
        "ALLOWED_CLIENT_DN_FRAGMENTS",
        "CN=remediation-agent",
    ).split(",")
    if item.strip()
}

ALLOWED_APPROVAL_SOURCES = {
    item.strip()
    for item in os.environ.get(
        "ALLOWED_APPROVAL_SOURCES",
        "remediation-agent-policy",
    ).split(",")
    if item.strip()
}

ALLOWED_TARGET_DEPLOYMENTS = {
    item.strip()
    for item in os.environ.get(
        "ALLOWED_TARGET_DEPLOYMENTS",
        "broken-app",
    ).split(",")
    if item.strip()
}

KUBECTL_TIMEOUT_SECONDS = int(
    os.environ.get(
        "KUBECTL_TIMEOUT_SECONDS",
        "15",
    )
)

publisher = pubsub_v1.PublisherClient()

guardian_topic_path = publisher.topic_path(
    PROJECT_ID,
    GUARDIAN_AUDIT_TOPIC,
)

security_events_topic_path = publisher.topic_path(
    PROJECT_ID,
    SECURITY_EVENTS_TOPIC,
)

DEPLOYMENT_NAME_RE = re.compile(
    r"^[a-z0-9]([-a-z0-9]{0,251}[a-z0-9])?$"
)


def publish_audit_event(
    event: dict[str, Any],
) -> None:
    encoded = json.dumps(
        event,
        sort_keys=True,
        default=str,
    ).encode("utf-8")

    severity = str(
        event.get(
            "severity",
            "INFORMATIONAL",
        )
    )

    futures = [
        publisher.publish(
            guardian_topic_path,
            encoded,
            source="mcp-audit",
            severity=severity,
            event_type="mcp-audit-event",
        ),
        publisher.publish(
            security_events_topic_path,
            encoded,
            source="mcp-audit",
            severity=severity,
            event_type="mcp-audit-event",
        ),
    ]

    try:
        for future in futures:
            future.result(timeout=20)

    except Exception as exc:
        print(
            json.dumps(
                {
                    "event": (
                        "mcp_audit_publish_failed"
                    ),
                    "error": str(exc),
                    "audit_event_id": event.get(
                        "event_id",
                        "",
                    ),
                }
            ),
            flush=True,
        )


def audit_severity(
    tool: str,
    outcome: str,
) -> str:
    if outcome in {
        "rejected",
        "error",
    }:
        return "HIGH"

    if (
        tool == "restart_deployment"
        and outcome == "success"
    ):
        return "MEDIUM"

    return "INFORMATIONAL"


def audit(
    tool: str,
    request_body: Any,
    outcome: str,
    detail: str = "",
) -> None:
    event = {
        "schema_version": "1.0",
        "event_id": str(uuid.uuid4()),
        "timestamp": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ",
            time.gmtime(),
        ),
        "source": "mcp-server",
        "severity": audit_severity(
            tool,
            outcome,
        ),
        "request_id": request.headers.get(
            "X-Request-ID",
            "",
        ),
        "client_dn": request.headers.get(
            "X-Client-DN",
            "",
        ),
        "target_namespace": TARGET_NAMESPACE,
        "tool": tool,
        "request": request_body,
        "outcome": outcome,
        "detail": detail[:1000],
    }

    threading.Thread(
        target=publish_audit_event,
        args=(event,),
        daemon=True,
    ).start()


@app.before_request
def require_verified_gateway_client() -> Any:
    if request.path in {
        "/healthz",
        "/readyz",
    }:
        return None

    if (
        request.headers.get(
            "X-Client-Verify"
        )
        != "SUCCESS"
    ):
        return (
            jsonify(
                {
                    "error": (
                        "verified mTLS client "
                        "identity is required"
                    )
                }
            ),
            403,
        )

    client_dn = request.headers.get(
        "X-Client-DN",
        "",
    )

    if (
        ALLOWED_CLIENT_DN_FRAGMENTS
        and not any(
            fragment in client_dn
            for fragment
            in ALLOWED_CLIENT_DN_FRAGMENTS
        )
    ):
        return (
            jsonify(
                {
                    "error": (
                        "mTLS client identity "
                        "is not authorized"
                    )
                }
            ),
            403,
        )

    return None


@app.get("/healthz")
def healthz() -> Any:
    return jsonify(
        {
            "status": "ok"
        }
    )


@app.get("/readyz")
def readyz() -> Any:
    return jsonify(
        {
            "status": "ready"
        }
    )


def get_validated_request() -> tuple[
    str | None,
    dict[str, Any] | None,
    Any,
]:
    body = request.get_json(
        silent=True
    )

    if (
        not isinstance(body, dict)
        or "deployment" not in body
    ):
        return (
            None,
            body,
            (
                jsonify(
                    {
                        "error": (
                            "missing 'deployment' "
                            "field"
                        )
                    }
                ),
                400,
            ),
        )

    deployment = body["deployment"]

    if (
        not isinstance(deployment, str)
        or not DEPLOYMENT_NAME_RE.fullmatch(
            deployment
        )
    ):
        return (
            None,
            body,
            (
                jsonify(
                    {
                        "error": (
                            "invalid 'deployment' "
                            "name"
                        )
                    }
                ),
                400,
            ),
        )

    requested_namespace = str(
        body.get(
            "namespace",
            TARGET_NAMESPACE,
        )
    )

    if requested_namespace != TARGET_NAMESPACE:
        return (
            None,
            body,
            (
                jsonify(
                    {
                        "error": (
                            "target namespace "
                            "is not allowlisted"
                        )
                    }
                ),
                403,
            ),
        )

    if (
        deployment
        not in ALLOWED_TARGET_DEPLOYMENTS
    ):
        return (
            None,
            body,
            (
                jsonify(
                    {
                        "error": (
                            "deployment is not in "
                            "the MCP target allowlist"
                        )
                    }
                ),
                403,
            ),
        )

    return deployment, body, None


def run_kubectl(
    args: list[str],
) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            [
                "kubectl",
                *args,
            ],
            capture_output=True,
            text=True,
            timeout=(
                KUBECTL_TIMEOUT_SECONDS
            ),
            check=False,
            env={
                **os.environ,
                "HOME": "/tmp",
            },
        )

    except subprocess.TimeoutExpired:
        return None


@app.get("/tools")
def tools() -> Any:
    return jsonify(
        {
            "tools": [
                "get_logs",
                "restart_deployment",
                "get_pods",
            ]
        }
    )


@app.post("/tool/get_logs")
def get_logs() -> Any:
    deployment, body, error = (
        get_validated_request()
    )

    if error:
        audit(
            "get_logs",
            body,
            "rejected",
            "request validation failed",
        )

        return error

    result = run_kubectl(
        [
            "logs",
            f"deployment/{deployment}",
            "-n",
            TARGET_NAMESPACE,
            "--all-containers=true",
            "--tail=50",
        ]
    )

    if result is None:
        audit(
            "get_logs",
            body,
            "error",
            "kubectl timed out",
        )

        return (
            jsonify(
                {
                    "error": (
                        "kubectl timed out"
                    )
                }
            ),
            504,
        )

    if result.returncode != 0:
        detail = result.stderr.strip()

        audit(
            "get_logs",
            body,
            "error",
            detail,
        )

        return (
            jsonify(
                {
                    "error": detail
                }
            ),
            502,
        )

    audit(
        "get_logs",
        body,
        "success",
    )

    return jsonify(
        {
            "logs": result.stdout
        }
    )


@app.post("/tool/get_pods")
def get_pods() -> Any:
    body = request.get_json(
        silent=True
    )

    if (
        body not in (None, {})
        and not isinstance(body, dict)
    ):
        return (
            jsonify(
                {
                    "error": (
                        "request body must "
                        "be a JSON object"
                    )
                }
            ),
            400,
        )

    result = run_kubectl(
        [
            "get",
            "pods",
            "-n",
            TARGET_NAMESPACE,
            "-o",
            "wide",
        ]
    )

    if result is None:
        audit(
            "get_pods",
            body or {},
            "error",
            "kubectl timed out",
        )

        return (
            jsonify(
                {
                    "error": (
                        "kubectl timed out"
                    )
                }
            ),
            504,
        )

    if result.returncode != 0:
        detail = result.stderr.strip()

        audit(
            "get_pods",
            body or {},
            "error",
            detail,
        )

        return (
            jsonify(
                {
                    "error": detail
                }
            ),
            502,
        )

    audit(
        "get_pods",
        body or {},
        "success",
    )

    return jsonify(
        {
            "pods": result.stdout
        }
    )


@app.post("/tool/restart_deployment")
def restart_deployment() -> Any:
    deployment, body, error = (
        get_validated_request()
    )

    if error:
        audit(
            "restart_deployment",
            body,
            "rejected",
            "request validation failed",
        )

        return error

    if (
        body.get("policy_approved")
        is not True
    ):
        audit(
            "restart_deployment",
            body,
            "rejected",
            (
                "policy_approved=true "
                "is required"
            ),
        )

        return (
            jsonify(
                {
                    "error": (
                        "remediation policy "
                        "approval is required"
                    )
                }
            ),
            403,
        )

    approval_source = str(
        body.get(
            "approval_source",
            "",
        )
    )

    if (
        approval_source
        not in ALLOWED_APPROVAL_SOURCES
    ):
        audit(
            "restart_deployment",
            body,
            "rejected",
            "unsupported approval source",
        )

        return (
            jsonify(
                {
                    "error": (
                        "unsupported approval source"
                    )
                }
            ),
            403,
        )

    required_audit_fields = [
        "policy_id",
        "incident_id",
        "analysis_id",
        "reason",
    ]

    missing = [
        field
        for field in required_audit_fields
        if not body.get(field)
    ]

    if missing:
        audit(
            "restart_deployment",
            body,
            "rejected",
            (
                "missing audit fields: "
                + ", ".join(missing)
            ),
        )

        return (
            jsonify(
                {
                    "error": (
                        "missing required "
                        "audit fields"
                    ),
                    "fields": missing,
                }
            ),
            400,
        )

    result = run_kubectl(
        [
            "rollout",
            "restart",
            f"deployment/{deployment}",
            "-n",
            TARGET_NAMESPACE,
        ]
    )

    if result is None:
        audit(
            "restart_deployment",
            body,
            "error",
            "kubectl timed out",
        )

        return (
            jsonify(
                {
                    "error": (
                        "kubectl timed out"
                    )
                }
            ),
            504,
        )

    if result.returncode != 0:
        detail = result.stderr.strip()

        audit(
            "restart_deployment",
            body,
            "error",
            detail,
        )

        return (
            jsonify(
                {
                    "error": detail
                }
            ),
            502,
        )

    detail = (
        result.stdout
        + result.stderr
    ).strip()

    audit(
        "restart_deployment",
        body,
        "success",
        detail,
    )

    return jsonify(
        {
            "result": detail,
            "policy_id": body[
                "policy_id"
            ],
            "incident_id": body[
                "incident_id"
            ],
            "analysis_id": body[
                "analysis_id"
            ],
        }
    )


if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=9000,
        debug=False,
    )