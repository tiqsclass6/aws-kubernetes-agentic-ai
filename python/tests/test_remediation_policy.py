import remediation_agent
from governance_models import GovernanceDecision


def governance_event(*, source: str = "dgc-opa", approval_required: bool = False) -> GovernanceDecision:
    approval = {
        "approval_id": "approval-1" if source == "kms-human-approval" else "",
        "approval_request_id": "request-1" if source == "kms-human-approval" else "",
        "approved": source == "kms-human-approval",
        "reviewer": "analyst@example.com" if source == "kms-human-approval" else "",
        "reason": "Approved after reviewing correlated evidence." if source == "kms-human-approval" else "",
        "issued_at": "2026-07-24T00:00:00Z" if source == "kms-human-approval" else "",
        "expires_at": "2099-07-24T00:10:00Z" if source == "kms-human-approval" else "",
        "key_version": "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1" if source == "kms-human-approval" else "",
        "signature_verified": source == "kms-human-approval",
    }
    return GovernanceDecision.model_validate(
        {
            "source": "approval-agent" if source == "kms-human-approval" else "governance-agent",
            "severity": "HIGH",
            "governance_decision_id": "governance-1",
            "analysis_id": "analysis-1",
            "incident_id": "incident-1",
            "decided_at": "2026-07-24T00:00:00Z",
            "expires_at": "2099-07-24T00:10:00Z",
            "decision_source": source,
            "decision": "PERMIT",
            "policy": {
                "policy_id": "phase5-remediation",
                "policy_version": "1.0.0",
                "policy_sha256": remediation_agent.LOCAL_POLICY_SHA256,
                "opa_path": "data.agentic.governance.decision",
                "automation_mode": "controlled",
                "decision": "PERMIT",
                "risk_tier": "low",
                "approval_required": approval_required,
                "approved": True,
                "reasons": ["controls passed"],
            },
            "approval": approval,
            "incident": {"incident_id": "incident-1", "signal_count": 3},
            "analysis": {
                "assessed_severity": "HIGH",
                "confidence": 0.97,
                "key_evidence": ["one", "two", "three"],
                "recommended_action": {
                    "action": "restart_deployment",
                    "target_namespace": "app01",
                    "target_deployment": "broken-app",
                    "operational_risk": "low",
                    "requires_human_approval": approval_required,
                },
            },
        }
    )


def test_executor_fails_closed_when_disabled(monkeypatch) -> None:
    monkeypatch.setattr(remediation_agent, "EXECUTION_MODE", "disabled")
    approved, reasons = remediation_agent.validate_governance_decision(governance_event())
    assert approved is False
    assert "EXECUTION_MODE is disabled" in reasons


def test_controlled_mode_accepts_automatic_permit(monkeypatch) -> None:
    monkeypatch.setattr(remediation_agent, "EXECUTION_MODE", "controlled")
    approved, reasons = remediation_agent.validate_governance_decision(governance_event())
    assert approved is True
    assert reasons == []


def test_approval_only_requires_verified_human_signature(monkeypatch) -> None:
    monkeypatch.setattr(remediation_agent, "EXECUTION_MODE", "approval-only")
    approved, reasons = remediation_agent.validate_governance_decision(
        governance_event(source="kms-human-approval", approval_required=True)
    )
    assert approved is True
    assert reasons == []
