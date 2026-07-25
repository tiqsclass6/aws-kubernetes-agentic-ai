from __future__ import annotations

import base64
import hashlib
import json
import os
from datetime import timedelta
from functools import lru_cache
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from google.cloud import firestore, kms_v1, pubsub_v1

from agent_runtime import AgentRuntime, stable_id
from governance_common import canonical_json_bytes, format_utc, parse_utc, utc_now
from governance_models import (
    ApprovalDecisionEnvelope,
    ApprovalMetadata,
    GovernanceDecision,
    GovernancePolicy,
)


PROJECT_ID = os.environ["PROJECT_ID"]
FIRESTORE_DATABASE = os.environ.get("FIRESTORE_DATABASE", "(default)")
APPROVAL_COLLECTION = os.environ.get("APPROVAL_COLLECTION", "approval_requests")
GOVERNANCE_AUDIT_TOPIC = os.environ.get(
    "GOVERNANCE_AUDIT_TOPIC",
    "governance-audit",
)
KMS_KEY_VERSION = os.environ["KMS_KEY_VERSION"]
MAX_CLOCK_SKEW_SECONDS = int(os.environ.get("MAX_CLOCK_SKEW_SECONDS", "120"))
PERMIT_TTL_SECONDS = int(os.environ.get("PERMIT_TTL_SECONDS", "600"))

firestore_client = firestore.Client(project=PROJECT_ID, database=FIRESTORE_DATABASE)
kms_client = kms_v1.KeyManagementServiceClient()
publisher = pubsub_v1.PublisherClient()
audit_topic_path = publisher.topic_path(PROJECT_ID, GOVERNANCE_AUDIT_TOPIC)


def publish_audit(event: dict[str, Any]) -> str:
    print(
        json.dumps(
            {"timestamp": AgentRuntime.utc_now(), "component": "approval-agent", **event},
            sort_keys=True,
            default=str,
        ),
        flush=True,
    )
    encoded = json.dumps(event, sort_keys=True, default=str).encode("utf-8")
    future = publisher.publish(
        audit_topic_path,
        encoded,
        source="approval-agent",
        event_type="governance-audit-event",
        severity=str(event.get("severity", "UNKNOWN"))[:256],
        schema_version="1.0",
    )
    return future.result(timeout=30)


@lru_cache(maxsize=1)
def approval_public_key() -> ec.EllipticCurvePublicKey:
    response = kms_client.get_public_key(request={"name": KMS_KEY_VERSION})
    public_key = serialization.load_pem_public_key(response.pem.encode("utf-8"))
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise RuntimeError("approval signing key must be an elliptic-curve public key")
    return public_key


def verify_signature(envelope: ApprovalDecisionEnvelope) -> None:
    if envelope.key_version != KMS_KEY_VERSION:
        raise ValueError("approval was signed by an unexpected KMS key version")

    try:
        signature = base64.b64decode(envelope.signature, validate=True)
    except ValueError as exc:
        raise ValueError("approval signature is not valid base64") from exc

    digest = hashlib.sha256(
        canonical_json_bytes(envelope.signed_payload())
    ).digest()

    try:
        approval_public_key().verify(
            signature,
            digest,
            ec.ECDSA(utils.Prehashed(hashes.SHA256())),
        )
    except InvalidSignature as exc:
        raise ValueError("approval signature verification failed") from exc


def validate_time_window(envelope: ApprovalDecisionEnvelope) -> None:
    now = utc_now()
    issued_at = parse_utc(envelope.issued_at)
    expires_at = parse_utc(envelope.expires_at)

    if issued_at > now + timedelta(seconds=MAX_CLOCK_SKEW_SECONDS):
        raise ValueError("approval issued_at is too far in the future")
    if expires_at <= now:
        raise ValueError("approval has expired")
    if expires_at <= issued_at:
        raise ValueError("approval expires_at must be after issued_at")
    if not envelope.reviewer.strip():
        raise ValueError("approval reviewer is required")
    if len(envelope.reason.strip()) < 10:
        raise ValueError("approval reason must contain at least 10 characters")


def resolved_decision(
    original: GovernanceDecision,
    envelope: ApprovalDecisionEnvelope,
) -> GovernanceDecision:
    now = utc_now()
    envelope_expiry = parse_utc(envelope.expires_at)
    permit_expiry = min(
        envelope_expiry,
        now + timedelta(seconds=PERMIT_TTL_SECONDS),
    )
    approved = envelope.decision == "APPROVE"
    decision_value = "PERMIT" if approved else "DENY"

    policy_data = original.policy.model_dump(mode="json")
    policy_data.update(
        {
            "decision": decision_value,
            "approved": approved,
            "reasons": [
                *original.policy.reasons,
                (
                    f"human approval by {envelope.reviewer}: {envelope.reason}"
                    if approved
                    else f"human denial by {envelope.reviewer}: {envelope.reason}"
                ),
            ],
        }
    )

    approval = ApprovalMetadata(
        approval_id=envelope.approval_id,
        approval_request_id=envelope.approval_request_id,
        approved=approved,
        reviewer=envelope.reviewer,
        reason=envelope.reason,
        issued_at=envelope.issued_at,
        expires_at=envelope.expires_at,
        key_version=envelope.key_version,
        signature_verified=True,
    )

    return GovernanceDecision(
        source="approval-agent",
        severity=original.severity,
        governance_decision_id=stable_id(
            "governance-decision",
            original.governance_decision_id,
            envelope.approval_id,
            decision_value,
        ),
        analysis_id=original.analysis_id,
        incident_id=original.incident_id,
        decided_at=format_utc(now),
        expires_at=format_utc(permit_expiry),
        decision_source="kms-human-approval",
        decision=decision_value,
        policy=GovernancePolicy.model_validate(policy_data),
        approval=approval,
        incident=original.incident,
        analysis=original.analysis,
    )


def resolve_approval(
    envelope: ApprovalDecisionEnvelope,
) -> tuple[GovernanceDecision, bool]:
    document = firestore_client.collection(APPROVAL_COLLECTION).document(
        envelope.approval_request_id
    )
    snapshot = document.get()
    if not snapshot.exists:
        raise ValueError("approval request does not exist")

    request_record = snapshot.to_dict() or {}
    if request_record.get("request_hash") != envelope.request_hash:
        raise ValueError("approval request hash does not match Firestore state")
    if request_record.get("governance_decision_id") != envelope.governance_decision_id:
        raise ValueError("approval is not bound to the expected governance decision")

    request_event = request_record.get("request_event")
    if not isinstance(request_event, dict):
        raise ValueError("approval request is missing its original event")

    request_expiry = parse_utc(str(request_event.get("expires_at", "")))
    if request_expiry <= utc_now():
        raise ValueError("approval request has expired")
    if parse_utc(envelope.expires_at) > request_expiry:
        raise ValueError("approval validity exceeds the original request expiry")

    original = GovernanceDecision.model_validate(request_event["governance_decision"])
    result = resolved_decision(original, envelope)
    transaction = firestore_client.transaction()

    @firestore.transactional
    def commit_resolution(current_transaction: Any) -> tuple[dict[str, Any], bool]:
        current = document.get(transaction=current_transaction)
        if not current.exists:
            raise ValueError("approval request disappeared during evaluation")

        data = current.to_dict() or {}
        status = str(data.get("status", "pending"))
        if status in {"approved", "denied"}:
            if data.get("approval_id") != envelope.approval_id:
                raise ValueError("approval request was already resolved by another decision")
            stored = data.get("resolved_decision")
            if not isinstance(stored, dict):
                raise ValueError("resolved approval is missing its stored decision")
            return stored, False

        if status != "pending":
            raise ValueError(f"approval request cannot be resolved from status {status}")

        result_payload = result.model_dump(mode="json")
        current_transaction.update(
            document,
            {
                "status": "approved" if envelope.decision == "APPROVE" else "denied",
                "approval_id": envelope.approval_id,
                "reviewer": envelope.reviewer,
                "resolution_reason": envelope.reason,
                "resolved_at": firestore.SERVER_TIMESTAMP,
                "resolved_decision": result_payload,
            },
        )
        return result_payload, True

    stored_payload, first_resolution = commit_resolution(transaction)
    return GovernanceDecision.model_validate(stored_payload), first_resolution


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    input_message_id: str,
) -> list[dict[str, Any]]:
    envelope = ApprovalDecisionEnvelope.model_validate(payload)
    validate_time_window(envelope)
    verify_signature(envelope)
    decision, first_resolution = resolve_approval(envelope)

    publish_audit(
        {
            "schema_version": "1.0",
            "event_type": "governance-audit-event",
            "source": "approval-agent",
            "severity": decision.severity,
            "audit_id": stable_id("approval-audit", envelope.approval_id),
            "created_at": AgentRuntime.utc_now(),
            "input_message_id": input_message_id,
            "approval_id": envelope.approval_id,
            "approval_request_id": envelope.approval_request_id,
            "governance_decision_id": decision.governance_decision_id,
            "decision": envelope.decision,
            "reviewer": envelope.reviewer,
            "signature_verified": True,
            "first_resolution": first_resolution,
        }
    )

    return [decision.model_dump(mode="json")]


def main() -> None:
    AgentRuntime(
        agent_name="approval-agent",
        processor=process,
        max_messages=int(os.environ.get("MAX_CONCURRENT_MESSAGES", "2")),
    ).run()


if __name__ == "__main__":
    main()
