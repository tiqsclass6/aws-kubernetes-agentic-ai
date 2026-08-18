from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)


@dataclass(frozen=True)
class MetricsResponse:
    body: bytes
    content_type: str = CONTENT_TYPE_LATEST


class ServiceMetrics:
    """Per-process Prometheus registry for a service."""

    def __init__(self, service_name: str) -> None:
        self.service_name = service_name
        self.registry = CollectorRegistry(auto_describe=True)

        labels = ["service"]

        self.ready = Gauge(
            "agent_ready",
            "Whether the agent subscriber is ready (1) or not ready (0).",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.inflight = Gauge(
            "agent_inflight_messages",
            "Messages currently being processed by the agent.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.last_success_unixtime = Gauge(
            "agent_last_success_unixtime",
            "Unix timestamp of the most recent successfully processed message.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.messages_received = Counter(
            "agent_messages_received_total",
            "Pub/Sub messages received by the agent.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.messages_processed = Counter(
            "agent_messages_processed_total",
            "Pub/Sub messages successfully processed and acknowledged.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.messages_failed = Counter(
            "agent_messages_failed_total",
            "Pub/Sub messages that failed processing and were negatively acknowledged.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.events_published = Counter(
            "agent_events_published_total",
            "Output events successfully published to Pub/Sub.",
            labels,
            registry=self.registry,
        ).labels(service=service_name)

        self.processing_seconds = Histogram(
            "agent_message_processing_seconds",
            "End-to-end processing duration for an input Pub/Sub message.",
            labels,
            buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120),
            registry=self.registry,
        ).labels(service=service_name)

        self.publish_seconds = Histogram(
            "agent_pubsub_publish_seconds",
            "Time spent publishing one output event to Pub/Sub.",
            labels,
            buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
            registry=self.registry,
        ).labels(service=service_name)

        self.processing_exceptions = Counter(
            "agent_processing_exceptions_total",
            "Unhandled processing exceptions grouped by exception type.",
            ["service", "exception_type"],
            registry=self.registry,
        )

        self.ready.set(0)
        self.inflight.set(0)
        self.last_success_unixtime.set(0)

    def mark_ready(self, ready: bool) -> None:
        self.ready.set(1 if ready else 0)

    def mark_success(self) -> None:
        self.messages_processed.inc()
        self.last_success_unixtime.set(time.time())

    def mark_exception(self, exc: BaseException) -> None:
        self.messages_failed.inc()
        self.processing_exceptions.labels(
            service=self.service_name,
            exception_type=type(exc).__name__,
        ).inc()

    def render(self) -> MetricsResponse:
        return MetricsResponse(body=generate_latest(self.registry))

    def snapshot(self) -> dict[str, Any]:
        """Small diagnostic payload used by unit tests and local debugging."""
        return {
            "service": self.service_name,
            "content_type": CONTENT_TYPE_LATEST,
            "metrics_bytes": len(generate_latest(self.registry)),
        }
