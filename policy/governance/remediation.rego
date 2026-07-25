package agentic.governance

import rego.v1

default decision := {
  "decision": "DENY",
  "risk_tier": "high",
  "approval_required": false,
  "reasons": ["no governance rule matched"],
}

no_action if input.action == "none"
no_action if input.action == "investigate"

namespace_allowed if input.target_namespace in input.allowed_namespaces
deployment_allowed if input.target_deployment in input.allowed_deployments
severity_actionable if input.assessed_severity in {"HIGH", "CRITICAL"}
risk_approvable if input.operational_risk in {"low", "medium"}

hard_denials contains "unsupported remediation action" if {
  not no_action
  input.action != "restart_deployment"
}

hard_denials contains "assessed severity is below HIGH" if {
  input.action == "restart_deployment"
  not severity_actionable
}

hard_denials contains "analysis confidence is below the approval threshold" if {
  input.action == "restart_deployment"
  input.confidence < input.thresholds.approval_confidence
}

hard_denials contains "operational risk is too high" if {
  input.action == "restart_deployment"
  not risk_approvable
}

hard_denials contains "target namespace is not allowlisted" if {
  input.action == "restart_deployment"
  not namespace_allowed
}

hard_denials contains "target deployment is not allowlisted" if {
  input.action == "restart_deployment"
  not deployment_allowed
}

hard_denials contains "incident has fewer than two correlated signals" if {
  input.action == "restart_deployment"
  input.signal_count < 2
}

hard_denials contains "analysis has fewer than two evidence items" if {
  input.action == "restart_deployment"
  input.evidence_count < 2
}

safe_candidate if {
  input.action == "restart_deployment"
  count(hard_denials) == 0
}

automatic_candidate if {
  safe_candidate
  input.automation_mode == "controlled"
  input.assessed_severity == "HIGH"
  input.confidence >= input.thresholds.automatic_confidence
  input.operational_risk == "low"
  not input.requires_human_approval
  input.signal_count >= input.thresholds.automatic_min_signals
  input.source_count >= input.thresholds.automatic_min_sources
  input.evidence_count >= input.thresholds.automatic_min_evidence
}

approval_candidate if {
  safe_candidate
  not automatic_candidate
}

approval_reasons contains "automation mode is not controlled" if {
  approval_candidate
  input.automation_mode != "controlled"
}

approval_reasons contains "analysis explicitly requires human approval" if {
  approval_candidate
  input.requires_human_approval
}

approval_reasons contains "CRITICAL incidents require human approval" if {
  approval_candidate
  input.assessed_severity == "CRITICAL"
}

approval_reasons contains "operational risk is medium" if {
  approval_candidate
  input.operational_risk == "medium"
}

approval_reasons contains "confidence is below the automatic threshold" if {
  approval_candidate
  input.confidence < input.thresholds.automatic_confidence
}

approval_reasons contains "signal count is below the automatic threshold" if {
  approval_candidate
  input.signal_count < input.thresholds.automatic_min_signals
}

approval_reasons contains "source diversity is below the automatic threshold" if {
  approval_candidate
  input.source_count < input.thresholds.automatic_min_sources
}

approval_reasons contains "evidence count is below the automatic threshold" if {
  approval_candidate
  input.evidence_count < input.thresholds.automatic_min_evidence
}

decision := {
  "decision": "NO_ACTION",
  "risk_tier": "low",
  "approval_required": false,
  "reasons": ["analysis recommended no operational change"],
} if no_action

decision := {
  "decision": "PERMIT",
  "risk_tier": "low",
  "approval_required": false,
  "reasons": ["all automatic remediation controls passed"],
} if automatic_candidate

decision := {
  "decision": "REQUIRE_APPROVAL",
  "risk_tier": input.operational_risk,
  "approval_required": true,
  "reasons": sort([reason | approval_reasons[reason]]),
} if approval_candidate

decision := {
  "decision": "DENY",
  "risk_tier": "high",
  "approval_required": false,
  "reasons": sort([reason | hard_denials[reason]]),
} if {
  not no_action
  count(hard_denials) > 0
}
