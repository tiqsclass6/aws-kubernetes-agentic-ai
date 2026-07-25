from __future__ import annotations

import os
from typing import Any

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
)

from agent_runtime import (
    AgentRuntime,
    stable_id,
)


class NormalizedFinding(BaseModel):
    model_config = ConfigDict(
        extra="allow"
    )

    schema_version: str = "1.0"
    finding_id: str
    event_time: str
    ingested_at: str
    source: str
    category: str
    severity: str
    status: str = "OPEN"
    title: str
    description: str = ""

    asset: dict[str, Any] = (
        Field(default_factory=dict)
    )

    evidence: dict[str, Any] = (
        Field(default_factory=dict)
    )

    labels: dict[str, str] = (
        Field(default_factory=dict)
    )


SEVERITY_WEIGHT = {
    "UNKNOWN": 5,
    "INFORMATIONAL": 2,
    "LOW": 8,
    "MEDIUM": 18,
    "HIGH": 35,
    "CRITICAL": 55,
}

SOURCE_BONUS = {
    "falco": 12,
    "security-command-center": 12,
    "trivy": 6,
    "prowler": 6,
    "cloud-logging": 4,
    "mcp-audit": 8,
    "mcp-server": 8,
}

CATEGORY_SIGNAL_MAP = {
    "runtime-security": (
        "runtime-anomaly"
    ),
    "container-vulnerability": (
        "vulnerability"
    ),
    "configuration-misconfiguration": (
        "misconfiguration"
    ),
    "embedded-secret": (
        "secret-exposure"
    ),
    "cloud-posture": (
        "cloud-posture-failure"
    ),
    "gke-log-event": (
        "platform-warning"
    ),
    "mcp-control-plane": (
        "control-plane-action"
    ),
}


def entity_key(
    finding: NormalizedFinding,
) -> str:
    asset = finding.asset

    namespace = str(
        asset.get(
            "namespace",
            "",
        )
    ).strip()

    pod = str(
        asset.get(
            "pod",
            "",
        )
    ).strip()

    deployment = str(
        asset.get(
            "deployment",
            "",
        )
    ).strip()

    image = str(
        asset.get(
            "image",
            "",
        )
    ).strip()

    resource_name = str(
        asset.get(
            "resource_name",
            "",
        )
    ).strip()

    project = str(
        asset.get(
            "project_id",
            asset.get(
                "project",
                "",
            ),
        )
    ).strip()

    if namespace and deployment:
        return (
            f"k8s:{namespace}:"
            f"deployment:{deployment}"
        )

    if namespace and pod:
        pod_owner = (
            pod.rsplit("-", 2)[0]
            if pod.count("-") >= 2
            else pod
        )

        return (
            f"k8s:{namespace}:"
            f"pod-owner:{pod_owner}"
        )

    if image:
        return f"image:{image}"

    if resource_name:
        return (
            f"gcp-resource:"
            f"{resource_name}"
        )

    if project:
        return f"gcp-project:{project}"

    return (
        f"finding:"
        f"{finding.finding_id}"
    )


def signal_type(
    finding: NormalizedFinding,
) -> str:
    category = (
        finding.category.lower()
    )

    if category in CATEGORY_SIGNAL_MAP:
        return CATEGORY_SIGNAL_MAP[
            category
        ]

    if finding.source == "falco":
        return "runtime-anomaly"

    if finding.source == "trivy":
        return "scanner-finding"

    if finding.source == "prowler":
        return (
            "cloud-posture-failure"
        )

    if (
        finding.source
        == "security-command-center"
    ):
        return "scc-finding"

    if finding.source in {
        "mcp-audit",
        "mcp-server",
    }:
        return "control-plane-action"

    return (
        category
        or "unclassified-signal"
    )


def disposition(
    severity: str,
    weight: int,
) -> str:
    if (
        severity == "CRITICAL"
        or weight >= 60
    ):
        return (
            "immediate-correlation"
        )

    if (
        severity == "HIGH"
        or weight >= 35
    ):
        return "correlate"

    if severity == "MEDIUM":
        return (
            "monitor-and-correlate"
        )

    return "monitor"


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    input_message_id: str,
) -> list[dict[str, Any]]:
    finding = (
        NormalizedFinding
        .model_validate(payload)
    )

    severity = (
        finding.severity.upper()
    )

    source = finding.source.lower()

    weight = min(
        100,
        SEVERITY_WEIGHT.get(
            severity,
            SEVERITY_WEIGHT["UNKNOWN"],
        )
        + SOURCE_BONUS.get(
            source,
            0,
        ),
    )

    entity = entity_key(finding)
    signal = signal_type(finding)

    observation = {
        "schema_version": "1.0",
        "event_type": (
            "observed-security-finding"
        ),
        "source": "observer-agent",
        "severity": severity,
        "observation_id": stable_id(
            "observation",
            finding.finding_id,
        ),
        "finding_id": (
            finding.finding_id
        ),
        "observed_at": (
            AgentRuntime.utc_now()
        ),
        "entity_key": entity,
        "signal_type": signal,
        "risk_weight": weight,
        "disposition": disposition(
            severity,
            weight,
        ),
        "input_message_id": (
            input_message_id
        ),
        "finding": finding.model_dump(
            mode="json"
        ),
    }

    return [observation]


def main() -> None:
    AgentRuntime(
        agent_name="observer-agent",
        processor=process,
        max_messages=int(
            os.environ.get(
                "MAX_CONCURRENT_MESSAGES",
                "20",
            )
        ),
    ).run()


if __name__ == "__main__":
    main()