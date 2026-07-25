from metrics_support import ServiceMetrics


def test_metrics_render_contains_service_and_counter() -> None:
    metrics = ServiceMetrics("unit-test-agent")
    metrics.messages_received.inc()
    metrics.mark_ready(True)
    rendered = metrics.render()

    text = rendered.body.decode("utf-8")
    assert 'agent_messages_received_total{service="unit-test-agent"} 1.0' in text
    assert 'agent_ready{service="unit-test-agent"} 1.0' in text
    assert rendered.content_type.startswith("text/plain")
