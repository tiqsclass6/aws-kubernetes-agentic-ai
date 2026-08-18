from __future__ import annotations

import hashlib
import json
import os
from datetime import timedelta
from pathlib import Path
from typing import Any

import requests
from google.cloud import firestore

from agent_runtime import AgentRuntime, stable_id
from governance_common import format_utc, is_sha256_hex, parse_utc, utc_now
from governance_models import GovernanceDecision


PROJECT_ID = os.environ["PROJECT_ID"]
FIRESTORE_DATABASE = os.environ.get("FIRESTORE_DATABASE", "(default)")
EXECUTION_COLLECTION = os.environ.get(
    "EXECUTION_COLLECTION",
    "remediation_executions",
)
EXECUTION_MODE = os.environ.get("EXECUTION_MODE", "disabled").strip().lower()
EXPECTED_POLICY_ID = os.environ.get("EXPECTED_POLICY_ID", "remediation")
POLICY_FILE = os.environ.get("POLICY_FILE", "/policies/remediation.rego")
EXECUTION_LEASE_SECONDS = int(os.environ.get("EXECUTION_LEASE_SECONDS", "180"))
EXECUTION_TTL_DAYS = int(os.environ.get("EXECUTION_TTL_DAYS", "30"))

MCP_GATEWAY_URL = os.environ.get(
    "MCP_GATEWAY_URL",
    "https://mcp-gateway.mcp-gateway.svc.cluster.local",
).rstrip("/")
MCP_CLIENT_CERT = os.environ.get(
    "MCP_CLIENT_CERT",
    "/var/run/mcp-client-tls/tls.crt",
)
MCP_CLIENT_KEY = os.environ.get(
    "MCP_CLIENT_KEY",
    "/var/run/mcp-client-tls/tls.key",
)
MCP_CA_CERT = os.environ.get(
    "MCP_CA_CERT",
    "/var/run/mcp-server-ca/ca.crt",
)
MCP_TIMEOUT_SECONDS = int(os.environ.get("MCP_TIMEOUT_SECONDS", "20"))

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

def local_policy_sha256() -> str:
    path = Path(POLICY_FILE)
    if not path.is_file():
        raise RuntimeError(f"executor governance policy file is missing: {POLICY_FILE}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


LOCAL_POLICY_SHA256 = local_policy_sha256()


http = requests.Session()
http.headers.update({"User-Agent": "agentic-remediation-agent/1.0"})
firestore_client = firestore.Client(project=PROJECT_ID, database=FIRESTORE_DATABASE)


def validate_tls_files() -> None:
    missing = [
        path
        for path in (MCP_CLIENT_CERT, MCP_CLIENT_KEY, MCP_CA_CERT)
        if not os.path.isfile(path)
    ]
    if missing:
        raise RuntimeError("missing required mTLS file(s): " + ", ".join(missing))


def validate_governance_decision(event: GovernanceDecision) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    action = event.analysis.recommended_action

    if event.decision != "PERMIT":
        reasons.append("governance decision is not PERMIT")

    if EXECUTION_MODE == "disabled":
        reasons.append("EXECUTION_MODE is disabled")
    elif EXECUTION_MODE == "approval-only":
        if event.decision_source != "kms-human-approval":
            reasons.append("approval-only mode requires a KMS human approval")
    elif EXECUTION_MODE != "controlled":
        reasons.append("EXECUTION_MODE must be disabled, approval-only, or controlled")

    if event.policy.policy_id != EXPECTED_POLICY_ID:
        reasons.append("governance policy ID does not match the executor allowlist")
    if not is_sha256_hex(event.policy.policy_sha256):
        reasons.append("governance policy SHA-256 is missing or malformed")
    elif event.policy.policy_sha256 != LOCAL_POLICY_SHA256:
        reasons.append("governance policy SHA-256 does not match the executor policy")
    if event.policy.decision != "PERMIT":
        reasons.append("embedded policy decision is not PERMIT")
    if not event.policy.approved:
        reasons.append("embedded policy approval flag is false")

    try:
        if parse_utc(event.expires_at) <= utc_now():
            reasons.append("governance decision has expired")
    except ValueError:
        reasons.append("governance decision expiry is malformed")

    if action.action != "restart_deployment":
        reasons.append("only restart_deployment is supported")
    if action.target_namespace not in ALLOWED_NAMESPACES:
        reasons.append("target namespace is not allowlisted")
    if action.target_deployment not in ALLOWED_DEPLOYMENTS:
        reasons.append("target deployment is not allowlisted")

    approval_required = event.policy.approval_required
    human_source = event.decision_source == "kms-human-approval"
    if approval_required or human_source:
        if not event.approval.approved:
            reasons.append("human approval flag is false")
        if not event.approval.signature_verified:
            reasons.append("human approval signature was not verified")
        if not event.approval.reviewer:
            reasons.append("human approval reviewer is missing")
        if not event.approval.key_version:
            reasons.append("human approval KMS key version is missing")

    if event.decision_source == "dgc-opa" and approval_required:
        reasons.append("OPA decision requiring approval cannot execute directly")

    return not reasons, reasons


def call_mcp_restart(event: GovernanceDecision) -> dict[str, Any]:
    action = event.analysis.recommended_action
    approval_source = (
        "kms-human-approval"
        if event.decision_source == "kms-human-approval"
        else "dgc-policy"
    )
    request_id = stable_id("remediation-request", event.governance_decision_id)

    response = http.post(
        f"{MCP_GATEWAY_URL}/tool/restart_deployment",
        json={
            "deployment": action.target_deployment,
            "namespace": action.target_namespace,
            "policy_approved": True,
            "approval_source": approval_source,
            "policy_id": event.policy.policy_id,
            "policy_version": event.policy.policy_version,
            "policy_sha256": event.policy.policy_sha256,
            "incident_id": event.incident_id,
            "analysis_id": event.analysis_id,
            "governance_decision_id": event.governance_decision_id,
            "approval_id": event.approval.approval_id,
            "reason": action.rationale,
            "confidence": event.analysis.confidence,
        },
        headers={"X-Request-ID": request_id},
        cert=(MCP_CLIENT_CERT, MCP_CLIENT_KEY),
        verify=MCP_CA_CERT,
        timeout=MCP_TIMEOUT_SECONDS,
    )

    if response.status_code >= 500:
        raise RuntimeError(
            f"MCP gateway returned transient status {response.status_code}: "
            f"{response.text[:500]}"
        )

    try:
        body = response.json()
    except ValueError:
        body = {"raw_response": response.text[:1000]}

    return {
        "accepted": response.status_code < 400,
        "status_code": response.status_code,
        "response": body,
    }


def claim_execution(event: GovernanceDecision) -> tuple[str, dict[str, Any] | None]:
    document = firestore_client.collection(EXECUTION_COLLECTION).document(
        stable_id("execution", event.governance_decision_id).split(":", 1)[1]
    )
    transaction = firestore_client.transaction()
    now = utc_now()
    lease_expires_at = now + timedelta(seconds=EXECUTION_LEASE_SECONDS)
    expires_at = now + timedelta(days=EXECUTION_TTL_DAYS)

    @firestore.transactional
    def claim(current_transaction: Any) -> tuple[str, dict[str, Any] | None]:
        snapshot = document.get(transaction=current_transaction)
        if snapshot.exists:
            data = snapshot.to_dict() or {}
            status = str(data.get("status", ""))
            if status == "completed" and isinstance(data.get("result"), dict):
                return "completed", data["result"]

            current_lease = data.get("lease_expires_at")
            if status == "executing" and current_lease is not None and current_lease > now:
                return "in-progress", None

        current_transaction.set(
            document,
            {
                "status": "executing",
                "governance_decision_id": event.governance_decision_id,
                "incident_id": event.incident_id,
                "analysis_id": event.analysis_id,
                "lease_expires_at": lease_expires_at,
                "expires_at": expires_at,
                "updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return "claimed", None

    return claim(transaction)


def complete_execution(event: GovernanceDecision, result: dict[str, Any]) -> None:
    document = firestore_client.collection(EXECUTION_COLLECTION).document(
        stable_id("execution", event.governance_decision_id).split(":", 1)[1]
    )
    document.set(
        {
            "status": "completed",
            "result": result,
            "completed_at": firestore.SERVER_TIMESTAMP,
            "lease_expires_at": utc_now(),
        },
        merge=True,
    )


def fail_execution(event: GovernanceDecision, error: Exception) -> None:
    document = firestore_client.collection(EXECUTION_COLLECTION).document(
        stable_id("execution", event.governance_decision_id).split(":", 1)[1]
    )
    document.set(
        {
            "status": "failed",
            "last_error": str(error)[:2000],
            "failed_at": firestore.SERVER_TIMESTAMP,
            "lease_expires_at": utc_now(),
        },
        merge=True,
    )


def build_result(
    event: GovernanceDecision,
    input_message_id: str,
    status: str,
    validation_reasons: list[str],
    gateway_result: dict[str, Any] | None = None,
) -> dict[str, Any]:
    action = event.analysis.recommended_action
    return {
        "schema_version": "1.0",
        "event_type": "remediation-result",
        "source": "remediation-agent",
        "severity": event.severity,
        "remediation_id": stable_id("remediation", event.governance_decision_id),
        "incident_id": event.incident_id,
        "analysis_id": event.analysis_id,
        "governance_decision_id": event.governance_decision_id,
        "processed_at": AgentRuntime.utc_now(),
        "input_message_id": input_message_id,
        "status": status,
        "action": action.model_dump(mode="json"),
        "policy": {
            **event.policy.model_dump(mode="json"),
            "execution_mode": EXECUTION_MODE,
            "executor_approved": not validation_reasons,
            "executor_reasons": validation_reasons,
        },
        "approval": event.approval.model_dump(mode="json"),
        "gateway_result": gateway_result or {},
        "incident": event.incident,
        "analysis": event.analysis.model_dump(mode="json"),
    }


def emit_evidence(result: dict[str, Any]) -> None:
    print(
        json.dumps(
            {
                "timestamp": AgentRuntime.utc_now(),
                "component": "remediation-agent",
                **result,
            },
            sort_keys=True,
            default=str,
        ),
        flush=True,
    )


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    input_message_id: str,
) -> list[dict[str, Any]]:
    event = GovernanceDecision.model_validate(payload)

    terminal_status = {
        "DENY": "denied-by-governance",
        "NO_ACTION": "no-action",
        "REQUIRE_APPROVAL": "awaiting-human-approval",
    }.get(event.decision)
    if terminal_status:
        result = build_result(event, input_message_id, terminal_status, [])
        emit_evidence(result)
        return [result]

    valid, reasons = validate_governance_decision(event)
    if not valid:
        result = build_result(event, input_message_id, "execution-blocked", reasons)
        emit_evidence(result)
        return [result]

    claim_status, stored_result = claim_execution(event)
    if claim_status == "completed" and stored_result is not None:
        emit_evidence(stored_result)
        return [stored_result]
    if claim_status == "in-progress":
        raise RuntimeError("remediation decision is already being executed")

    try:
        gateway_result = call_mcp_restart(event)
        status = "executed" if gateway_result["accepted"] else "rejected-by-gateway"
        result = build_result(
            event,
            input_message_id,
            status,
            [],
            gateway_result,
        )
        complete_execution(event, result)
        emit_evidence(result)
        return [result]
    except Exception as exc:
        fail_execution(event, exc)
        raise


def main() -> None:
    validate_tls_files()
    AgentRuntime(
        agent_name="remediation-agent",
        processor=process,
        max_messages=int(os.environ.get("MAX_CONCURRENT_MESSAGES", "2")),
    ).run()


if __name__ == "__main__":
    main()
