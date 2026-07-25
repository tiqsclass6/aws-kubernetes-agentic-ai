from __future__ import annotations

import hashlib
import json
import os
import time
from datetime import timedelta
from pathlib import Path
from typing import Any

import requests
from google.cloud import firestore, pubsub_v1
from pydantic import BaseModel, ConfigDict, Field

from agent_runtime import AgentRuntime, stable_id
from governance_common import format_utc, sha256_hex, utc_now
from governance_models import AnalyzedIncident, GovernanceDecision, GovernancePolicy


class OpaPolicyResult(BaseModel):
    model_config = ConfigDict(extra="allow")

    decision: str
    risk_tier: str = "high"
    approval_required: bool = False
    reasons: list[str] = Field(default_factory=list)


PROJECT_ID = os.environ["PROJECT_ID"]
FIRESTORE_DATABASE = os.environ.get("FIRESTORE_DATABASE", "(default)")
APPROVAL_COLLECTION = os.environ.get("APPROVAL_COLLECTION", "approval_requests")
APPROVAL_REQUESTS_TOPIC = os.environ.get(
    "APPROVAL_REQUESTS_TOPIC",
    "approval-requests",
)
GOVERNANCE_AUDIT_TOPIC = os.environ.get(
    "GOVERNANCE_AUDIT_TOPIC",
    "governance-audit",
)
OPA_DECISION_URL = os.environ.get(
    "OPA_DECISION_URL",
    "http://127.0.0.1:8181/v1/data/agentic/governance/decision",
)
OPA_TIMEOUT_SECONDS = int(os.environ.get("OPA_TIMEOUT_SECONDS", "5"))
POLICY_FILE = os.environ.get(
    "POLICY_FILE",
    "/policies/remediation.rego",
)
POLICY_ID = os.environ.get("POLICY_ID", "phase5-remediation")
POLICY_VERSION = os.environ.get("POLICY_VERSION", "1.0.0")
AUTOMATION_MODE = os.environ.get("AUTOMATION_MODE", "disabled").strip().lower()
DECISION_TTL_SECONDS = int(os.environ.get("DECISION_TTL_SECONDS", "900"))
APPROVAL_TTL_SECONDS = int(os.environ.get("APPROVAL_TTL_SECONDS", "1800"))
APPROVAL_CONFIDENCE = float(os.environ.get("APPROVAL_CONFIDENCE", "0.85"))
AUTOMATIC_CONFIDENCE = float(os.environ.get("AUTOMATIC_CONFIDENCE", "0.95"))
AUTOMATIC_MIN_SIGNALS = int(os.environ.get("AUTOMATIC_MIN_SIGNALS", "3"))
AUTOMATIC_MIN_SOURCES = int(os.environ.get("AUTOMATIC_MIN_SOURCES", "2"))
AUTOMATIC_MIN_EVIDENCE = int(os.environ.get("AUTOMATIC_MIN_EVIDENCE", "3"))
ALLOWED_NAMESPACES = {
    value.strip()
    for value in os.environ.get("ALLOWED_NAMESPACES", "app01").split(",")
    if value.strip()
}
ALLOWED_DEPLOYMENTS = {
    value.strip()
    for value in os.environ.get("ALLOWED_DEPLOYMENTS", "broken-app").split(",")
    if value.strip()
}

http = requests.Session()
http.headers.update({"User-Agent": "agentic-governance-agent/phase5"})

publisher = pubsub_v1.PublisherClient()
approval_topic_path = publisher.topic_path(PROJECT_ID, APPROVAL_REQUESTS_TOPIC)
audit_topic_path = publisher.topic_path(PROJECT_ID, GOVERNANCE_AUDIT_TOPIC)
firestore_client = firestore.Client(project=PROJECT_ID, database=FIRESTORE_DATABASE)


def policy_sha256() -> str:
    path = Path(POLICY_FILE)
    if not path.is_file():
        raise RuntimeError(f"governance policy file is missing: {POLICY_FILE}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


POLICY_SHA256 = policy_sha256()


def publish_extra(topic_path: str, event: dict[str, Any]) -> str:
    encoded = json.dumps(event, sort_keys=True, default=str).encode("utf-8")
    future = publisher.publish(
        topic_path,
        encoded,
        source=str(event.get("source", "governance-agent"))[:256],
        event_type=str(event.get("event_type", "governance-event"))[:256],
        severity=str(event.get("severity", "UNKNOWN"))[:256],
        schema_version=str(event.get("schema_version", "1.0"))[:256],
    )
    return future.result(timeout=30)


def build_policy_input(event: AnalyzedIncident) -> dict[str, Any]:
    action = event.analysis.recommended_action
    sources = event.incident.get("sources", [])

    return {
        "analysis_id": event.analysis_id,
        "incident_id": str(event.incident.get("incident_id", "")),
        "action": action.action,
        "target_namespace": action.target_namespace,
        "target_deployment": action.target_deployment,
        "assessed_severity": event.analysis.assessed_severity,
        "confidence": event.analysis.confidence,
        "operational_risk": action.operational_risk,
        "requires_human_approval": action.requires_human_approval,
        "signal_count": int(event.incident.get("signal_count", 0)),
        "source_count": len(sources) if isinstance(sources, list) else 0,
        "evidence_count": len(event.analysis.key_evidence),
        "automation_mode": AUTOMATION_MODE,
        "allowed_namespaces": sorted(ALLOWED_NAMESPACES),
        "allowed_deployments": sorted(ALLOWED_DEPLOYMENTS),
        "thresholds": {
            "approval_confidence": APPROVAL_CONFIDENCE,
            "automatic_confidence": AUTOMATIC_CONFIDENCE,
            "automatic_min_signals": AUTOMATIC_MIN_SIGNALS,
            "automatic_min_sources": AUTOMATIC_MIN_SOURCES,
            "automatic_min_evidence": AUTOMATIC_MIN_EVIDENCE,
        },
    }


def evaluate_with_opa(policy_input: dict[str, Any]) -> OpaPolicyResult:
    response = http.post(
        OPA_DECISION_URL,
        json={"input": policy_input},
        timeout=OPA_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    body = response.json()
    if "result" not in body:
        raise RuntimeError("OPA returned no decision result")

    result = OpaPolicyResult.model_validate(body["result"])
    if result.decision not in {"PERMIT", "DENY", "REQUIRE_APPROVAL", "NO_ACTION"}:
        raise RuntimeError(f"OPA returned unsupported decision: {result.decision}")
    if result.risk_tier not in {"low", "medium", "high"}:
        raise RuntimeError(f"OPA returned unsupported risk tier: {result.risk_tier}")
    return result


def approval_request_binding(
    decision: GovernanceDecision,
    approval_request_id: str,
    expires_at: str,
) -> dict[str, Any]:
    action = decision.analysis.recommended_action
    return {
        "approval_request_id": approval_request_id,
        "governance_decision_id": decision.governance_decision_id,
        "analysis_id": decision.analysis_id,
        "incident_id": decision.incident_id,
        "policy_sha256": decision.policy.policy_sha256,
        "action": action.action,
        "target_namespace": action.target_namespace,
        "target_deployment": action.target_deployment,
        "expires_at": expires_at,
    }


def persist_approval_request(
    request_event: dict[str, Any],
    expires_at_datetime: Any,
) -> str:
    document = firestore_client.collection(APPROVAL_COLLECTION).document(
        request_event["approval_request_id"]
    )
    transaction = firestore_client.transaction()

    @firestore.transactional
    def write_request(current_transaction: Any) -> str:
        snapshot = document.get(transaction=current_transaction)
        if snapshot.exists:
            existing = snapshot.to_dict() or {}
            if existing.get("request_hash") != request_event["request_hash"]:
                raise RuntimeError("approval request ID collision detected")
            return str(existing.get("status", "pending"))

        current_transaction.set(
            document,
            {
                "status": "pending",
                "approval_request_id": request_event["approval_request_id"],
                "governance_decision_id": request_event["governance_decision_id"],
                "analysis_id": request_event["analysis_id"],
                "incident_id": request_event["incident_id"],
                "request_hash": request_event["request_hash"],
                "request_event": request_event,
                "created_at": firestore.SERVER_TIMESTAMP,
                "expires_at": expires_at_datetime,
            },
        )
        return "created"

    return write_request(transaction)


def build_governance_decision(
    event: AnalyzedIncident,
    result: OpaPolicyResult,
    input_message_id: str,
) -> GovernanceDecision:
    now = utc_now()
    incident_id = str(event.incident.get("incident_id", ""))
    decision_id = stable_id(
        "governance-decision",
        event.analysis_id,
        POLICY_SHA256,
        result.decision,
    )

    policy = GovernancePolicy(
        policy_id=POLICY_ID,
        policy_version=POLICY_VERSION,
        policy_sha256=POLICY_SHA256,
        opa_path="data.agentic.governance.decision",
        automation_mode=AUTOMATION_MODE,
        decision=result.decision,
        risk_tier=result.risk_tier,
        approval_required=result.approval_required,
        approved=result.decision == "PERMIT" and not result.approval_required,
        reasons=result.reasons,
    )

    return GovernanceDecision(
        source="governance-agent",
        severity=event.analysis.assessed_severity,
        governance_decision_id=decision_id,
        analysis_id=event.analysis_id,
        incident_id=incident_id,
        decided_at=format_utc(now),
        expires_at=format_utc(now + timedelta(seconds=DECISION_TTL_SECONDS)),
        decision_source="dgc-opa",
        decision=result.decision,
        policy=policy,
        incident=event.incident,
        analysis=event.analysis,
        input_message_id=input_message_id,
    )


def create_approval_request(decision: GovernanceDecision) -> dict[str, Any]:
    now = utc_now()
    expires_at_datetime = now + timedelta(seconds=APPROVAL_TTL_SECONDS)
    expires_at = format_utc(expires_at_datetime)
    request_id = stable_id("approval-request", decision.governance_decision_id)
    binding = approval_request_binding(decision, request_id, expires_at)

    request_event = {
        "schema_version": "1.0",
        "event_type": "approval-request",
        "source": "governance-agent",
        "severity": decision.severity,
        "approval_request_id": request_id,
        "governance_decision_id": decision.governance_decision_id,
        "analysis_id": decision.analysis_id,
        "incident_id": decision.incident_id,
        "created_at": format_utc(now),
        "expires_at": expires_at,
        "request_hash": sha256_hex(binding),
        "binding": binding,
        "governance_decision": decision.model_dump(mode="json"),
    }

    status = persist_approval_request(request_event, expires_at_datetime)
    if status in {"created", "pending"}:
        publish_extra(approval_topic_path, request_event)

    return request_event


def publish_audit(
    decision: GovernanceDecision,
    approval_request: dict[str, Any] | None,
) -> None:
    event = {
        "schema_version": "1.0",
        "event_type": "governance-audit-event",
        "source": "governance-agent",
        "severity": decision.severity,
        "audit_id": stable_id("governance-audit", decision.governance_decision_id),
        "created_at": AgentRuntime.utc_now(),
        "governance_decision_id": decision.governance_decision_id,
        "analysis_id": decision.analysis_id,
        "incident_id": decision.incident_id,
        "decision": decision.decision,
        "decision_source": decision.decision_source,
        "policy": decision.policy.model_dump(mode="json"),
        "approval_request_id": (
            approval_request.get("approval_request_id", "")
            if approval_request
            else ""
        ),
    }
    print(
        json.dumps(
            {"timestamp": AgentRuntime.utc_now(), "component": "governance-agent", **event},
            sort_keys=True,
            default=str,
        ),
        flush=True,
    )
    publish_extra(audit_topic_path, event)


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    input_message_id: str,
) -> list[dict[str, Any]]:
    event = AnalyzedIncident.model_validate(payload)
    policy_input = build_policy_input(event)
    result = evaluate_with_opa(policy_input)
    decision = build_governance_decision(event, result, input_message_id)

    approval_request: dict[str, Any] | None = None
    if decision.decision == "REQUIRE_APPROVAL":
        approval_request = create_approval_request(decision)

    publish_audit(decision, approval_request)
    return [decision.model_dump(mode="json")]



def wait_for_opa() -> None:
    deadline = time.monotonic() + int(os.environ.get("OPA_STARTUP_TIMEOUT_SECONDS", "60"))
    health_url = OPA_DECISION_URL.split("/v1/data/", 1)[0] + "/health"
    last_error = ""
    while time.monotonic() < deadline:
        try:
            response = http.get(health_url, timeout=2)
            if response.status_code == 200:
                return
            last_error = f"status {response.status_code}"
        except requests.RequestException as exc:
            last_error = str(exc)
        time.sleep(1)
    raise RuntimeError(f"OPA did not become ready: {last_error}")


def main() -> None:
    wait_for_opa()
    AgentRuntime(
        agent_name="governance-agent",
        processor=process,
        max_messages=int(os.environ.get("MAX_CONCURRENT_MESSAGES", "4")),
    ).run()


if __name__ == "__main__":
    main()
