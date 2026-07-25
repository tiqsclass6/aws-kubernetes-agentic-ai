from __future__ import annotations

import hashlib
import json
import os
import signal
import threading
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from flask import Flask, jsonify, request
from google.cloud import pubsub_v1
from google.cloud.pubsub_v1.subscriber.message import Message

PROJECT_ID = os.environ["PROJECT_ID"]

RAW_EVENTS_SUBSCRIPTION = os.getenv(
    "RAW_EVENTS_SUBSCRIPTION",
    "raw-security-events-sub",
)

FINDINGS_TOPIC = os.getenv(
    "FINDINGS_TOPIC",
    "security-findings",
)

HTTP_PORT = int(
    os.getenv(
        "HTTP_PORT",
        "8080",
    )
)

MAX_FINDINGS_PER_EVENT = int(
    os.getenv(
        "MAX_FINDINGS_PER_EVENT",
        "500",
    )
)

PUBLISH_PASSED_FINDINGS = (
    os.getenv(
        "PUBLISH_PASSED_FINDINGS",
        "false",
    ).lower()
    == "true"
)

app = Flask(__name__)

app.config["MAX_CONTENT_LENGTH"] = (
    16 * 1024 * 1024
)

publisher = (
    pubsub_v1.PublisherClient()
)

subscriber = (
    pubsub_v1.SubscriberClient()
)

findings_topic_path = (
    publisher.topic_path(
        PROJECT_ID,
        FINDINGS_TOPIC,
    )
)

raw_subscription_path = (
    subscriber.subscription_path(
        PROJECT_ID,
        RAW_EVENTS_SUBSCRIPTION,
    )
)

state_lock = threading.Lock()

state: dict[str, Any] = {
    "subscriber_started": False,
    "last_message_at": None,
    "last_publish_at": None,
    "published_findings": 0,
    "failed_events": 0,
    "last_error": "",
}


def now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def log(
    event: str,
    **fields: Any,
) -> None:
    print(
        json.dumps(
            {
                "timestamp": now(),
                "component": (
                    "event-aggregator"
                ),
                "event": event,
                **fields,
            },
            sort_keys=True,
            default=str,
        ),
        flush=True,
    )


def text(
    value: Any,
    limit: int = 4000,
) -> str:
    if value is None:
        return ""

    rendered = (
        value
        if isinstance(value, str)
        else json.dumps(
            value,
            sort_keys=True,
            default=str,
        )
    )

    return rendered[:limit]


def digest(
    value: Any,
) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        default=str,
        separators=(",", ":"),
    ).encode("utf-8")

    return hashlib.sha256(
        encoded
    ).hexdigest()


def severity(
    value: Any,
) -> str:
    if isinstance(
        value,
        (int, float),
    ):
        return {
            1: "INFORMATIONAL",
            2: "LOW",
            3: "MEDIUM",
            4: "HIGH",
            5: "CRITICAL",
        }.get(
            int(value),
            "UNKNOWN",
        )

    normalized = str(
        value or "UNKNOWN"
    ).upper().strip()

    aliases = {
        "INFO": "INFORMATIONAL",
        "NOTICE": "MEDIUM",
        "WARN": "MEDIUM",
        "WARNING": "MEDIUM",
        "ERR": "HIGH",
        "ERROR": "HIGH",
        "FATAL": "CRITICAL",
        "SEVERE": "CRITICAL",
        "EMERGENCY": "CRITICAL",
        "ALERT": "CRITICAL",
    }

    normalized = aliases.get(
        normalized,
        normalized,
    )

    allowed = {
        "INFORMATIONAL",
        "LOW",
        "MEDIUM",
        "HIGH",
        "CRITICAL",
    }

    return (
        normalized
        if normalized in allowed
        else "UNKNOWN"
    )


def finding(
    *,
    source: str,
    category: str,
    severity_value: Any,
    title: str,
    description: str,
    event_time: Any = None,
    asset: dict[str, Any] | None = None,
    evidence: dict[str, Any] | None = None,
    labels: dict[str, str] | None = None,
    finding_id: str | None = None,
    status: str = "OPEN",
    raw_event: Any = None,
) -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "finding_id": (
            finding_id
            or str(uuid.uuid4())
        ),
        "event_time": str(
            event_time or now()
        ),
        "ingested_at": now(),
        "source": (
            source.lower()
            .replace("_", "-")
        ),
        "category": category,
        "severity": severity(
            severity_value
        ),
        "status": status,
        "title": text(
            title,
            300,
        ),
        "description": text(
            description
        ),
        "asset": asset or {},
        "evidence": evidence or {},
        "labels": labels or {},
        "raw_event_sha256": digest(
            raw_event
        ),
    }


def normalize_falco(
    payload: dict[str, Any],
) -> list[dict[str, Any]]:
    fields = (
        payload.get("output_fields")
        or {}
    )

    rule = str(
        payload.get("rule")
        or "Falco runtime event"
    )

    return [
        finding(
            source="falco",
            category="runtime-security",
            severity_value=(
                payload.get("priority")
            ),
            title=rule,
            description=payload.get(
                "output",
                rule,
            ),
            event_time=payload.get(
                "time"
            ),
            asset={
                "namespace": (
                    fields.get(
                        "k8s.ns.name"
                    )
                    or fields.get(
                        "k8smeta.namespace.name",
                        "",
                    )
                ),
                "pod": (
                    fields.get(
                        "k8s.pod.name"
                    )
                    or fields.get(
                        "k8smeta.pod.name",
                        "",
                    )
                ),
                "container": (
                    fields.get(
                        "container.name",
                        "",
                    )
                ),
                "container_id": (
                    fields.get(
                        "container.id",
                        "",
                    )
                ),
                "image": (
                    fields.get(
                        "container.image.repository",
                        "",
                    )
                ),
                "host": payload.get(
                    "hostname",
                    "",
                ),
            },
            evidence={
                "rule": rule,
                "output": payload.get(
                    "output",
                    "",
                ),
                "output_fields": fields,
                "tags": payload.get(
                    "tags",
                    [],
                ),
            },
            labels={
                "event_source": str(
                    payload.get(
                        "source",
                        "syscall",
                    )
                )
            },
            raw_event=payload,
        )
    ]


def normalize_trivy_report(
    payload: dict[str, Any],
) -> list[dict[str, Any]]:
    findings: list[
        dict[str, Any]
    ] = []

    image = str(
        payload.get("ArtifactName")
        or "unknown-image"
    )

    for result in (
        payload.get("Results")
        or []
    ):
        target = str(
            result.get("Target")
            or image
        )

        for item in (
            result.get(
                "Vulnerabilities"
            )
            or []
        ):
            vuln_id = str(
                item.get(
                    "VulnerabilityID"
                )
                or uuid.uuid4()
            )

            package = str(
                item.get("PkgName")
                or "unknown-package"
            )

            findings.append(
                finding(
                    source="trivy",
                    category=(
                        "container-vulnerability"
                    ),
                    severity_value=(
                        item.get("Severity")
                    ),
                    title=(
                        item.get("Title")
                        or (
                            f"{vuln_id} "
                            f"in {package}"
                        )
                    ),
                    description=item.get(
                        "Description",
                        "",
                    ),
                    event_time=payload.get(
                        "CreatedAt"
                    ),
                    finding_id=(
                        "trivy:"
                        + digest(
                            [
                                image,
                                target,
                                vuln_id,
                                package,
                            ]
                        )
                    ),
                    asset={
                        "image": image,
                        "target": target,
                    },
                    evidence={
                        "vulnerability_id": (
                            vuln_id
                        ),
                        "package": package,
                        "installed_version": (
                            item.get(
                                "InstalledVersion",
                                "",
                            )
                        ),
                        "fixed_version": (
                            item.get(
                                "FixedVersion",
                                "",
                            )
                        ),
                        "primary_url": (
                            item.get(
                                "PrimaryURL",
                                "",
                            )
                        ),
                    },
                    raw_event=item,
                )
            )

        for item in (
            result.get(
                "Misconfigurations"
            )
            or []
        ):
            check_id = str(
                item.get("ID")
                or uuid.uuid4()
            )

            findings.append(
                finding(
                    source="trivy",
                    category=(
                        "configuration-"
                        "misconfiguration"
                    ),
                    severity_value=(
                        item.get("Severity")
                    ),
                    title=item.get(
                        "Title",
                        check_id,
                    ),
                    description=item.get(
                        "Description",
                        "",
                    ),
                    event_time=payload.get(
                        "CreatedAt"
                    ),
                    finding_id=(
                        "trivy:"
                        + digest(
                            [
                                image,
                                target,
                                check_id,
                            ]
                        )
                    ),
                    asset={
                        "image": image,
                        "target": target,
                    },
                    evidence={
                        "check_id": check_id,
                        "message": item.get(
                            "Message",
                            "",
                        ),
                        "resolution": (
                            item.get(
                                "Resolution",
                                "",
                            )
                        ),
                    },
                    raw_event=item,
                )
            )

        for item in (
            result.get("Secrets")
            or []
        ):
            rule_id = str(
                item.get("RuleID")
                or uuid.uuid4()
            )

            findings.append(
                finding(
                    source="trivy",
                    category=(
                        "embedded-secret"
                    ),
                    severity_value=(
                        item.get(
                            "Severity",
                            "HIGH",
                        )
                    ),
                    title=item.get(
                        "Title",
                        rule_id,
                    ),
                    description=item.get(
                        "Match",
                        (
                            "Potential secret "
                            "detected"
                        ),
                    ),
                    event_time=payload.get(
                        "CreatedAt"
                    ),
                    finding_id=(
                        "trivy:"
                        + digest(
                            [
                                image,
                                target,
                                rule_id,
                                item.get(
                                    "StartLine"
                                ),
                            ]
                        )
                    ),
                    asset={
                        "image": image,
                        "target": target,
                    },
                    evidence={
                        "rule_id": rule_id,
                        "category": item.get(
                            "Category",
                            "",
                        ),
                        "start_line": (
                            item.get(
                                "StartLine"
                            )
                        ),
                        "end_line": (
                            item.get(
                                "EndLine"
                            )
                        ),
                        "code": item.get(
                            "Code",
                            {},
                        ),
                    },
                    raw_event=item,
                )
            )

        if (
            len(findings)
            >= MAX_FINDINGS_PER_EVENT
        ):
            break

    if findings:
        return findings[
            :MAX_FINDINGS_PER_EVENT
        ]

    return [
        finding(
            source="trivy",
            category="scan-summary",
            severity_value=(
                "INFORMATIONAL"
            ),
            title=(
                "Trivy scan completed "
                f"for {image}"
            ),
            description=(
                "No vulnerability, "
                "misconfiguration, or "
                "secret findings were "
                "returned."
            ),
            event_time=payload.get(
                "CreatedAt"
            ),
            asset={
                "image": image
            },
            status="CLOSED",
            raw_event=payload,
        )
    ]


def normalize_trivy(
    payload: Any,
) -> list[dict[str, Any]]:
    reports = (
        payload
        if isinstance(payload, list)
        else [payload]
    )

    findings: list[
        dict[str, Any]
    ] = []

    for report in reports:
        if not isinstance(
            report,
            dict,
        ):
            continue

        findings.extend(
            normalize_trivy_report(
                report
            )
        )

        if (
            len(findings)
            >= MAX_FINDINGS_PER_EVENT
        ):
            break

    return findings[
        :MAX_FINDINGS_PER_EVENT
    ]


def normalize_prowler(
    payload: Any,
) -> list[dict[str, Any]]:
    items = (
        payload
        if isinstance(payload, list)
        else [payload]
    )

    findings: list[
        dict[str, Any]
    ] = []

    for item in items:
        if not isinstance(
            item,
            dict,
        ):
            continue

        status = str(
            item.get("status_code")
            or item.get("status")
            or ""
        ).upper()

        if (
            status == "PASS"
            and not PUBLISH_PASSED_FINDINGS
        ):
            continue

        info = (
            item.get("finding_info")
            or {}
        )

        metadata = (
            item.get("metadata")
            or {}
        )

        resources = (
            item.get("resources")
            or []
        )

        resource = (
            resources[0]
            if (
                resources
                and isinstance(
                    resources[0],
                    dict,
                )
            )
            else {}
        )

        check_id = str(
            metadata.get("event_code")
            or "prowler-check"
        )

        unique_id = str(
            info.get("uid")
            or item.get("activity_id")
            or digest(item)
        )

        findings.append(
            finding(
                source="prowler",
                category="cloud-posture",
                severity_value=item.get(
                    "severity",
                    item.get(
                        "severity_id"
                    ),
                ),
                title=info.get(
                    "title",
                    check_id,
                ),
                description=(
                    item.get(
                        "status_detail"
                    )
                    or item.get(
                        "message"
                    )
                    or info.get(
                        "desc",
                        "",
                    )
                ),
                event_time=(
                    item.get("time_dt")
                    or item.get("time")
                ),
                finding_id=(
                    f"prowler:{unique_id}"
                ),
                status=(
                    "OPEN"
                    if status
                    in {
                        "",
                        "FAIL",
                        "NEW",
                    }
                    else status
                ),
                asset={
                    "uid": resource.get(
                        "uid",
                        "",
                    ),
                    "name": resource.get(
                        "name",
                        "",
                    ),
                    "type": resource.get(
                        "type",
                        "",
                    ),
                    "region": resource.get(
                        "region",
                        "",
                    ),
                },
                evidence={
                    "check_id": check_id,
                    "status_code": status,
                    "risk_details": (
                        item.get(
                            "risk_details",
                            "",
                        )
                    ),
                    "remediation": (
                        item.get(
                            "remediation",
                            {},
                        )
                    ),
                    "compliance": (
                        (
                            item.get(
                                "unmapped"
                            )
                            or {}
                        ).get(
                            "compliance",
                            {},
                        )
                    ),
                },
                labels={
                    "provider": "gcp",
                    "scanner": "prowler",
                },
                raw_event=item,
            )
        )

        if (
            len(findings)
            >= MAX_FINDINGS_PER_EVENT
        ):
            break

    return findings


def normalize_scc(
    payload: dict[str, Any],
) -> list[dict[str, Any]]:
    item = (
        payload.get("finding")
        or payload
    )

    resource = (
        payload.get("resource")
        or {}
    )

    name = str(
        item.get("name")
        or digest(item)
    )

    category = str(
        item.get("category")
        or "security-command-center"
    )

    return [
        finding(
            source=(
                "security-command-center"
            ),
            category=category,
            severity_value=item.get(
                "severity"
            ),
            title=(
                category.replace(
                    "_",
                    " ",
                ).title()
            ),
            description=(
                item.get("description")
                or category
            ),
            event_time=(
                item.get("eventTime")
                or item.get("createTime")
            ),
            finding_id=f"scc:{name}",
            status=str(
                item.get("state")
                or "ACTIVE"
            ),
            asset={
                "resource_name": (
                    item.get(
                        "resourceName",
                        "",
                    )
                ),
                "display_name": (
                    resource.get(
                        "displayName",
                        "",
                    )
                ),
                "project": (
                    resource.get(
                        "projectDisplayName",
                        "",
                    )
                ),
                "type": resource.get(
                    "type",
                    "",
                ),
                "location": (
                    resource.get(
                        "location",
                        "",
                    )
                ),
            },
            evidence={
                "source_properties": (
                    item.get(
                        "sourceProperties",
                        {},
                    )
                ),
                "indicator": item.get(
                    "indicator",
                    {},
                ),
                "vulnerability": (
                    item.get(
                        "vulnerability",
                        {},
                    )
                ),
            },
            labels={
                "provider": "gcp"
            },
            raw_event=payload,
        )
    ]


def normalize_logging(
    payload: dict[str, Any],
) -> list[dict[str, Any]]:
    resource = (
        payload.get("resource")
        or {}
    )

    labels = (
        resource.get("labels")
        or {}
    )

    json_payload = (
        payload.get("jsonPayload")
        or {}
    )

    proto_payload = (
        payload.get("protoPayload")
        or {}
    )

    description = (
        json_payload.get("message")
        or (
            proto_payload.get("status")
            or {}
        ).get("message")
        or payload.get("textPayload")
        or text(
            json_payload
            or proto_payload
        )
    )

    title = (
        json_payload.get("reason")
        or proto_payload.get(
            "methodName"
        )
        or "GKE security log event"
    )

    return [
        finding(
            source="cloud-logging",
            category="gke-log-event",
            severity_value=(
                payload.get("severity")
            ),
            title=str(title),
            description=str(
                description
            ),
            event_time=(
                payload.get("timestamp")
                or payload.get(
                    "receiveTimestamp"
                )
            ),
            finding_id=(
                "gcp-log:"
                + str(
                    payload.get(
                        "insertId"
                    )
                    or digest(payload)
                )
            ),
            asset={
                "resource_type": (
                    resource.get(
                        "type",
                        "",
                    )
                ),
                "project_id": (
                    labels.get(
                        "project_id",
                        "",
                    )
                ),
                "cluster": labels.get(
                    "cluster_name",
                    "",
                ),
                "namespace": labels.get(
                    "namespace_name",
                    "",
                ),
                "pod": labels.get(
                    "pod_name",
                    "",
                ),
                "container": labels.get(
                    "container_name",
                    "",
                ),
                "node": labels.get(
                    "node_name",
                    "",
                ),
                "location": labels.get(
                    "location",
                    "",
                ),
            },
            evidence={
                "log_name": payload.get(
                    "logName",
                    "",
                ),
                "json_payload": (
                    json_payload
                ),
                "proto_payload": (
                    proto_payload
                ),
                "text_payload": (
                    payload.get(
                        "textPayload",
                        "",
                    )
                ),
            },
            labels={
                "provider": "gcp"
            },
            raw_event=payload,
        )
    ]


def normalize_mcp_audit(
    payload: dict[str, Any],
) -> list[dict[str, Any]]:
    request_payload = (
        payload.get("request")
        or {}
    )

    if not isinstance(
        request_payload,
        dict,
    ):
        request_payload = {
            "raw": request_payload
        }

    tool = str(
        payload.get("tool")
        or "unknown-tool"
    )

    outcome = str(
        payload.get("outcome")
        or "unknown"
    ).lower()

    deployment = str(
        request_payload.get(
            "deployment"
        )
        or ""
    )

    namespace = str(
        request_payload.get(
            "namespace"
        )
        or payload.get(
            "target_namespace"
        )
        or ""
    )

    category = (
        "automated-remediation"
        if tool
        == "restart_deployment"
        else "mcp-control-plane"
    )

    title = (
        f"MCP {tool} {outcome}"
    )

    description = str(
        payload.get("detail")
        or title
    )

    return [
        finding(
            source="mcp-server",
            category=category,
            severity_value=(
                payload.get(
                    "severity",
                    "UNKNOWN",
                )
            ),
            title=title,
            description=description,
            event_time=payload.get(
                "timestamp"
            ),
            finding_id=(
                "mcp:"
                + str(
                    payload.get(
                        "event_id"
                    )
                    or digest(payload)
                )
            ),
            status=(
                "OPEN"
                if outcome
                in {
                    "rejected",
                    "error",
                }
                else "CLOSED"
            ),
            asset={
                "namespace": namespace,
                "deployment": deployment,
                "tool": tool,
            },
            evidence={
                "request_id": (
                    payload.get(
                        "request_id",
                        "",
                    )
                ),
                "client_dn": payload.get(
                    "client_dn",
                    "",
                ),
                "request": request_payload,
                "outcome": outcome,
                "detail": payload.get(
                    "detail",
                    "",
                ),
            },
            labels={
                "control_plane": "mcp",
                "outcome": outcome,
            },
            raw_event=payload,
        )
    ]


def normalize(
    source: str,
    payload: Any,
) -> list[dict[str, Any]]:
    source = (
        source.lower()
        .replace("_", "-")
    )

    if (
        source == "falco"
        and isinstance(
            payload,
            dict,
        )
    ):
        return normalize_falco(
            payload
        )

    if source == "trivy":
        return normalize_trivy(
            payload
        )

    if source == "prowler":
        return normalize_prowler(
            payload
        )

    if (
        source
        in {
            "scc",
            "security-command-center",
        }
        and isinstance(
            payload,
            dict,
        )
    ):
        return normalize_scc(
            payload
        )

    if (
        source
        in {
            "cloud-logging",
            "gcp-logging",
        }
        and isinstance(
            payload,
            dict,
        )
    ):
        return normalize_logging(
            payload
        )

    if (
        source
        in {
            "mcp",
            "mcp-server",
        }
        and isinstance(
            payload,
            dict,
        )
    ):
        return normalize_mcp_audit(
            payload
        )

    if isinstance(payload, dict):
        if "finding" in payload:
            return normalize_scc(
                payload
            )

        if (
            "logName" in payload
            or "protoPayload" in payload
        ):
            return normalize_logging(
                payload
            )

        if (
            "rule" in payload
            and "priority" in payload
        ):
            return normalize_falco(
                payload
            )

        if (
            "SchemaVersion"
            in payload
            and "Results" in payload
        ):
            return normalize_trivy(
                payload
            )

        if (
            "finding_info"
            in payload
        ):
            return normalize_prowler(
                payload
            )

        if (
            payload.get("source")
            == "mcp-server"
            and "tool" in payload
        ):
            return normalize_mcp_audit(
                payload
            )

    if (
        isinstance(payload, list)
        and payload
        and isinstance(
            payload[0],
            dict,
        )
    ):
        if (
            "finding_info"
            in payload[0]
        ):
            return normalize_prowler(
                payload
            )

        if (
            "SchemaVersion"
            in payload[0]
            and "Results"
            in payload[0]
        ):
            return normalize_trivy(
                payload
            )

    return [
        finding(
            source=(
                source or "unknown"
            ),
            category=(
                "unclassified-"
                "security-event"
            ),
            severity_value=(
                payload.get("severity")
                if isinstance(
                    payload,
                    dict,
                )
                else "UNKNOWN"
            ),
            title=(
                "Unclassified event "
                f"from {source}"
            ),
            description=text(payload),
            evidence={
                "payload": payload
            },
            raw_event=payload,
        )
    ]


def publish(
    findings: Iterable[
        dict[str, Any]
    ],
) -> int:
    futures = []
    count = 0

    for item in findings:
        futures.append(
            publisher.publish(
                findings_topic_path,
                json.dumps(
                    item,
                    sort_keys=True,
                    default=str,
                ).encode("utf-8"),
                source=item["source"],
                severity=item[
                    "severity"
                ],
                category=item[
                    "category"
                ],
                schema_version=item[
                    "schema_version"
                ],
            )
        )

        count += 1

    for future in futures:
        future.result(
            timeout=30
        )

    if count:
        with state_lock:
            state[
                "published_findings"
            ] += count

            state[
                "last_publish_at"
            ] = now()

            state["last_error"] = ""

    return count


def process(
    source: str,
    payload: Any,
) -> int:
    return publish(
        normalize(
            source,
            payload,
        )
    )


def infer_source(
    payload: Any,
    attributes: dict[str, str],
) -> str:
    if (
        attributes.get("source")
        or attributes.get(
            "event_source"
        )
    ):
        return (
            attributes.get("source")
            or attributes[
                "event_source"
            ]
        )

    if isinstance(payload, dict):
        if "finding" in payload:
            return (
                "security-command-center"
            )

        if (
            "logName" in payload
            or "protoPayload" in payload
        ):
            return "cloud-logging"

        if "rule" in payload:
            return "falco"

        if (
            payload.get("source")
            == "mcp-server"
            and "tool" in payload
        ):
            return "mcp-server"

    return "pubsub"


def callback(
    message: Message,
) -> None:
    try:
        payload = json.loads(
            message.data.decode(
                "utf-8"
            )
        )

        source = infer_source(
            payload,
            dict(message.attributes),
        )

        count = process(
            source,
            payload,
        )

        with state_lock:
            state[
                "last_message_at"
            ] = now()

            state["last_error"] = ""

        log(
            "raw_event_processed",
            source=source,
            finding_count=count,
            message_id=(
                message.message_id
            ),
        )

        message.ack()

    except Exception as exc:
        with state_lock:
            state[
                "failed_events"
            ] += 1

            state["last_error"] = str(
                exc
            )

        log(
            "raw_event_failed",
            error=str(exc),
            message_id=(
                message.message_id
            ),
        )

        message.nack()


def subscription_loop() -> None:
    future = subscriber.subscribe(
        raw_subscription_path,
        callback=callback,
        flow_control=(
            pubsub_v1.types.FlowControl(
                max_messages=20,
                max_bytes=(
                    20 * 1024 * 1024
                ),
            )
        ),
    )

    with state_lock:
        state[
            "subscriber_started"
        ] = True

    log(
        "pubsub_subscriber_started",
        subscription=(
            raw_subscription_path
        ),
    )

    try:
        future.result()

    except Exception as exc:
        with state_lock:
            state[
                "subscriber_started"
            ] = False

            state["last_error"] = str(
                exc
            )

        log(
            "pubsub_subscriber_stopped",
            error=str(exc),
        )


@app.get("/healthz")
def healthz():
    return jsonify(
        {
            "status": "ok"
        }
    )


@app.get("/readyz")
def readyz():
    with state_lock:
        snapshot = dict(state)

    ready = bool(
        snapshot[
            "subscriber_started"
        ]
    )

    return (
        jsonify(
            {
                "status": (
                    "ready"
                    if ready
                    else "not-ready"
                ),
                **snapshot,
            }
        ),
        200 if ready else 503,
    )


@app.get("/status")
def status():
    with state_lock:
        return jsonify(
            dict(state)
        )


@app.post("/ingest/<source>")
def ingest(
    source: str,
):
    payload = request.get_json(
        silent=True
    )

    if payload is None:
        return (
            jsonify(
                {
                    "error": (
                        "request body must "
                        "be valid JSON"
                    )
                }
            ),
            400,
        )

    try:
        count = process(
            source,
            payload,
        )

        log(
            "http_event_processed",
            source=source,
            finding_count=count,
        )

        return (
            jsonify(
                {
                    "accepted": True,
                    "published_findings": (
                        count
                    ),
                }
            ),
            202,
        )

    except Exception as exc:
        with state_lock:
            state[
                "failed_events"
            ] += 1

            state["last_error"] = str(
                exc
            )

        log(
            "http_event_failed",
            source=source,
            error=str(exc),
        )

        return (
            jsonify(
                {
                    "accepted": False,
                    "error": str(exc),
                }
            ),
            500,
        )


def shutdown(
    signum: int,
    _frame: Any,
) -> None:
    log(
        "shutdown_requested",
        signal=signum,
    )

    subscriber.close()

    raise SystemExit(0)


def main() -> None:
    signal.signal(
        signal.SIGTERM,
        shutdown,
    )

    signal.signal(
        signal.SIGINT,
        shutdown,
    )

    threading.Thread(
        target=subscription_loop,
        daemon=True,
    ).start()

    log(
        "event_aggregator_started",
        project_id=PROJECT_ID,
        raw_subscription=(
            RAW_EVENTS_SUBSCRIPTION
        ),
        findings_topic=(
            FINDINGS_TOPIC
        ),
        port=HTTP_PORT,
    )

    app.run(
        host="0.0.0.0",
        port=HTTP_PORT,
        debug=False,
        threaded=True,
    )


if __name__ == "__main__":
    main()