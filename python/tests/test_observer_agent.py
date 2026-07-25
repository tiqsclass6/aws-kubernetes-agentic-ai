from observer_agent import NormalizedFinding, disposition, entity_key, signal_type


def sample_finding() -> NormalizedFinding:
    return NormalizedFinding(
        finding_id="finding-1",
        event_time="2026-07-24T00:00:00Z",
        ingested_at="2026-07-24T00:00:01Z",
        source="falco",
        category="runtime-security",
        severity="HIGH",
        title="Runtime anomaly",
        asset={"namespace": "app01", "deployment": "broken-app"},
    )


def test_observer_builds_stable_kubernetes_entity() -> None:
    finding = sample_finding()
    assert entity_key(finding) == "k8s:app01:deployment:broken-app"
    assert signal_type(finding) == "runtime-anomaly"


def test_high_weight_is_correlated() -> None:
    assert disposition("HIGH", 47) == "correlate"
    assert disposition("CRITICAL", 67) == "immediate-correlation"
