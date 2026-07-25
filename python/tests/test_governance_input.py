import governance_agent
from governance_models import AnalyzedIncident


def analyzed_event() -> AnalyzedIncident:
    return AnalyzedIncident.model_validate(
        {
            "analysis_id": "analysis-1",
            "analyzed_at": "2026-07-24T00:00:00Z",
            "incident": {
                "incident_id": "incident-1",
                "signal_count": 3,
                "sources": ["falco", "cloud-logging"],
            },
            "analysis": {
                "assessed_severity": "HIGH",
                "confidence": 0.97,
                "key_evidence": ["one", "two", "three"],
                "recommended_action": {
                    "action": "restart_deployment",
                    "target_namespace": "app01",
                    "target_deployment": "broken-app",
                    "operational_risk": "low",
                    "requires_human_approval": False,
                },
            },
        }
    )


def test_policy_input_contains_deterministic_controls(monkeypatch) -> None:
    monkeypatch.setattr(governance_agent, "AUTOMATION_MODE", "disabled")
    policy_input = governance_agent.build_policy_input(analyzed_event())
    assert policy_input["automation_mode"] == "disabled"
    assert policy_input["signal_count"] == 3
    assert policy_input["source_count"] == 2
    assert policy_input["evidence_count"] == 3
    assert policy_input["allowed_namespaces"] == ["app01"]
