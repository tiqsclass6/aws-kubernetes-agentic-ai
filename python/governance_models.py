from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class RecommendedAction(BaseModel):
    action: Literal["none", "investigate", "restart_deployment"]
    target_namespace: str = ""
    target_deployment: str = ""
    rationale: str = ""
    expected_outcome: str = ""
    operational_risk: Literal["low", "medium", "high"] = "high"
    requires_human_approval: bool = True


class IRAnalysis(BaseModel):
    model_config = ConfigDict(extra="allow")

    assessed_severity: Literal["LOW", "MEDIUM", "HIGH", "CRITICAL"]
    confidence: float
    likely_root_cause: str = ""
    key_evidence: list[str] = Field(default_factory=list)
    containment_steps: list[str] = Field(default_factory=list)
    investigation_steps: list[str] = Field(default_factory=list)
    executive_summary: str = ""
    recommended_action: RecommendedAction

    @field_validator("confidence")
    @classmethod
    def validate_confidence(cls, value: float) -> float:
        if not 0 <= value <= 1:
            raise ValueError("confidence must be between 0 and 1")
        return value


class AnalyzedIncident(BaseModel):
    model_config = ConfigDict(extra="allow")

    schema_version: str = "1.0"
    analysis_id: str
    analyzed_at: str
    incident: dict[str, Any]
    analysis: IRAnalysis


class GovernancePolicy(BaseModel):
    model_config = ConfigDict(extra="allow")

    policy_id: str
    policy_version: str
    policy_sha256: str
    opa_path: str
    automation_mode: str
    decision: Literal["PERMIT", "DENY", "REQUIRE_APPROVAL", "NO_ACTION"]
    risk_tier: Literal["low", "medium", "high"]
    approval_required: bool
    approved: bool = False
    reasons: list[str] = Field(default_factory=list)


class ApprovalMetadata(BaseModel):
    model_config = ConfigDict(extra="allow")

    approval_id: str = ""
    approval_request_id: str = ""
    approved: bool = False
    reviewer: str = ""
    reason: str = ""
    issued_at: str = ""
    expires_at: str = ""
    key_version: str = ""
    signature_verified: bool = False


class GovernanceDecision(BaseModel):
    model_config = ConfigDict(extra="allow")

    schema_version: str = "1.0"
    event_type: str = "governance-decision"
    source: str
    severity: str
    governance_decision_id: str
    analysis_id: str
    incident_id: str
    decided_at: str
    expires_at: str
    decision_source: Literal["dgc-opa", "kms-human-approval"]
    decision: Literal["PERMIT", "DENY", "REQUIRE_APPROVAL", "NO_ACTION"]
    policy: GovernancePolicy
    approval: ApprovalMetadata = Field(default_factory=ApprovalMetadata)
    incident: dict[str, Any]
    analysis: IRAnalysis


class ApprovalDecisionEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: str = "1.0"
    event_type: Literal["approval-decision"] = "approval-decision"
    approval_id: str
    approval_request_id: str
    governance_decision_id: str
    decision: Literal["APPROVE", "DENY"]
    reviewer: str
    reason: str
    issued_at: str
    expires_at: str
    request_hash: str
    key_version: str
    signature: str

    def signed_payload(self) -> dict[str, Any]:
        return self.model_dump(mode="json", exclude={"signature"})
