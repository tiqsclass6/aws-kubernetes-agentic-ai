import base64
import hashlib

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

import approval_agent
from governance_common import canonical_json_bytes
from governance_models import ApprovalDecisionEnvelope


def unsigned_payload() -> dict:
    return {
        "schema_version": "1.0",
        "event_type": "approval-decision",
        "approval_id": "approval-1",
        "approval_request_id": "approval-request-1",
        "governance_decision_id": "governance-1",
        "decision": "APPROVE",
        "reviewer": "analyst@example.com",
        "reason": "Reviewed the evidence and approved the controlled restart.",
        "issued_at": "2026-07-24T00:00:00Z",
        "expires_at": "2026-07-24T00:10:00Z",
        "request_hash": "a" * 64,
        "key_version": approval_agent.KMS_KEY_VERSION,
    }


def test_valid_ecdsa_signature_is_accepted(monkeypatch) -> None:
    private_key = ec.generate_private_key(ec.SECP256R1())
    payload = unsigned_payload()
    digest = hashlib.sha256(canonical_json_bytes(payload)).digest()
    signature = private_key.sign(
        digest,
        ec.ECDSA(utils.Prehashed(hashes.SHA256())),
    )
    envelope = ApprovalDecisionEnvelope.model_validate(
        {**payload, "signature": base64.b64encode(signature).decode("ascii")}
    )
    monkeypatch.setattr(approval_agent, "approval_public_key", private_key.public_key)
    approval_agent.verify_signature(envelope)


def test_modified_payload_is_rejected(monkeypatch) -> None:
    private_key = ec.generate_private_key(ec.SECP256R1())
    payload = unsigned_payload()
    digest = hashlib.sha256(canonical_json_bytes(payload)).digest()
    signature = private_key.sign(
        digest,
        ec.ECDSA(utils.Prehashed(hashes.SHA256())),
    )
    envelope = ApprovalDecisionEnvelope.model_validate(
        {
            **payload,
            "reason": "This payload was changed after it was signed.",
            "signature": base64.b64encode(signature).decode("ascii"),
        }
    )
    monkeypatch.setattr(approval_agent, "approval_public_key", private_key.public_key)
    try:
        approval_agent.verify_signature(envelope)
    except ValueError as exc:
        assert "verification failed" in str(exc)
    else:
        raise AssertionError("modified signed payload was accepted")
