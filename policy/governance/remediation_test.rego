package agentic.governance_test

import rego.v1
import data.agentic.governance

base_input := {
  "action": "restart_deployment",
  "target_namespace": "app01",
  "target_deployment": "broken-app",
  "assessed_severity": "HIGH",
  "confidence": 0.97,
  "operational_risk": "low",
  "requires_human_approval": false,
  "signal_count": 3,
  "source_count": 2,
  "evidence_count": 3,
  "automation_mode": "controlled",
  "allowed_namespaces": ["app01"],
  "allowed_deployments": ["broken-app"],
  "thresholds": {
    "approval_confidence": 0.85,
    "automatic_confidence": 0.95,
    "automatic_min_signals": 3,
    "automatic_min_sources": 2,
    "automatic_min_evidence": 3,
  },
}

test_low_risk_high_confidence_action_is_permitted if {
  governance.decision.decision == "PERMIT" with input as base_input
}

test_disabled_automation_requires_approval if {
  candidate := object.union(base_input, {"automation_mode": "disabled"})
  governance.decision.decision == "REQUIRE_APPROVAL" with input as candidate
  governance.decision.approval_required with input as candidate
}

test_critical_incident_requires_approval if {
  candidate := object.union(base_input, {"assessed_severity": "CRITICAL"})
  governance.decision.decision == "REQUIRE_APPROVAL" with input as candidate
}

test_unapproved_namespace_is_denied if {
  candidate := object.union(base_input, {"target_namespace": "kube-system"})
  governance.decision.decision == "DENY" with input as candidate
}

test_investigation_is_no_action if {
  candidate := object.union(base_input, {"action": "investigate"})
  governance.decision.decision == "NO_ACTION" with input as candidate
}
