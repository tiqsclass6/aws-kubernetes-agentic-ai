from __future__ import annotations

import json
import os
import signal
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterable

from google.cloud import pubsub_v1
from google.cloud.pubsub_v1.subscriber.message import Message

from metrics_support import ServiceMetrics

Processor = Callable[
    [dict[str, Any], dict[str, str], str],
    Iterable[dict[str, Any]] | None,
]


class AgentRuntime:
    """Common Pub/Sub runtime with health, readiness, status, and metrics."""

    def __init__(
        self,
        *,
        agent_name: str,
        processor: Processor,
        project_id: str | None = None,
        input_subscription: str | None = None,
        output_topic: str | None = None,
        health_port: int | None = None,
        max_messages: int = 10,
        max_bytes: int = 20 * 1024 * 1024,
    ) -> None:
        self.agent_name = agent_name
        self.processor = processor
        self.project_id = project_id or os.environ["PROJECT_ID"]
        self.input_subscription = (
            input_subscription or os.environ["INPUT_SUBSCRIPTION"]
        )
        self.output_topic = output_topic or os.environ.get("OUTPUT_TOPIC", "")
        self.health_port = health_port or int(os.environ.get("HEALTH_PORT", "8080"))
        self.max_output_bytes = int(
            os.environ.get("MAX_OUTPUT_BYTES", str(9 * 1024 * 1024))
        )

        self.publisher = pubsub_v1.PublisherClient()
        self.subscriber = pubsub_v1.SubscriberClient()
        self.subscription_path = self.subscriber.subscription_path(
            self.project_id,
            self.input_subscription,
        )
        self.output_topic_path = (
            self.publisher.topic_path(self.project_id, self.output_topic)
            if self.output_topic
            else ""
        )
        self.flow_control = pubsub_v1.types.FlowControl(
            max_messages=max_messages,
            max_bytes=max_bytes,
        )

        self.metrics = ServiceMetrics(agent_name)
        self.stop_event = threading.Event()
        self.state_lock = threading.Lock()
        self.streaming_future: Any = None
        self.state: dict[str, Any] = {
            "subscriber_started": False,
            "last_message_at": "",
            "last_success_at": "",
            "last_error": "",
            "received_messages": 0,
            "processed_messages": 0,
            "published_events": 0,
            "failed_messages": 0,
            "inflight_messages": 0,
        }

    @staticmethod
    def utc_now() -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    def log(self, event: str, **fields: Any) -> None:
        print(
            json.dumps(
                {
                    "timestamp": self.utc_now(),
                    "component": self.agent_name,
                    "event": event,
                    **fields,
                },
                sort_keys=True,
                default=str,
            ),
            flush=True,
        )

    def _update_state(self, **fields: Any) -> None:
        with self.state_lock:
            self.state.update(fields)

    def snapshot(self) -> dict[str, Any]:
        with self.state_lock:
            return dict(self.state)

    def publish(self, event: dict[str, Any]) -> str:
        if not self.output_topic_path:
            raise RuntimeError("OUTPUT_TOPIC is not configured")

        encoded = json.dumps(event, sort_keys=True, default=str).encode("utf-8")
        if len(encoded) > self.max_output_bytes:
            raise ValueError(
                f"output event is {len(encoded)} bytes; maximum is "
                f"{self.max_output_bytes} bytes"
            )

        attributes = {
            "source": str(event.get("source", self.agent_name))[:256],
            "event_type": str(event.get("event_type", "security-event"))[:256],
            "severity": str(event.get("severity", "UNKNOWN"))[:256],
            "schema_version": str(event.get("schema_version", "1.0"))[:256],
        }

        started = time.monotonic()
        try:
            future = self.publisher.publish(
                self.output_topic_path,
                encoded,
                **attributes,
            )
            message_id = future.result(timeout=30)
        finally:
            self.metrics.publish_seconds.observe(time.monotonic() - started)

        self.metrics.events_published.inc()
        with self.state_lock:
            self.state["published_events"] += 1
        return message_id

    def _callback(self, message: Message) -> None:
        started = time.monotonic()
        self.metrics.messages_received.inc()
        self.metrics.inflight.inc()

        with self.state_lock:
            self.state["last_message_at"] = self.utc_now()
            self.state["received_messages"] += 1
            self.state["inflight_messages"] += 1

        try:
            payload = json.loads(message.data.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("Pub/Sub message must contain a JSON object")

            outputs = list(
                self.processor(
                    payload,
                    dict(message.attributes),
                    message.message_id,
                )
                or []
            )
            published_ids = [self.publish(event) for event in outputs]
            message.ack()

            self.metrics.mark_success()
            with self.state_lock:
                self.state["processed_messages"] += 1
                self.state["last_success_at"] = self.utc_now()
                self.state["last_error"] = ""

            self.log(
                "message_processed",
                input_message_id=message.message_id,
                output_count=len(outputs),
                output_message_ids=published_ids,
                duration_seconds=round(time.monotonic() - started, 6),
            )
        except Exception as exc:
            message.nack()
            self.metrics.mark_exception(exc)

            with self.state_lock:
                self.state["failed_messages"] += 1
                self.state["last_error"] = str(exc)

            self.log(
                "message_failed",
                input_message_id=message.message_id,
                error=str(exc),
                exception_type=type(exc).__name__,
                duration_seconds=round(time.monotonic() - started, 6),
            )
        finally:
            self.metrics.processing_seconds.observe(time.monotonic() - started)
            self.metrics.inflight.dec()
            with self.state_lock:
                self.state["inflight_messages"] = max(
                    0,
                    self.state["inflight_messages"] - 1,
                )

    def _health_handler(self) -> type[BaseHTTPRequestHandler]:
        runtime = self

        class HealthHandler(BaseHTTPRequestHandler):
            def _send_json(self, status: int, payload: dict[str, Any]) -> None:
                body = json.dumps(payload, sort_keys=True).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:  # noqa: N802
                snapshot = runtime.snapshot()

                if self.path == "/healthz":
                    self._send_json(200, {"status": "ok", "agent": runtime.agent_name})
                    return

                if self.path == "/readyz":
                    ready = bool(snapshot["subscriber_started"])
                    self._send_json(
                        200 if ready else 503,
                        {
                            "status": "ready" if ready else "not-ready",
                            "agent": runtime.agent_name,
                            "last_error": snapshot["last_error"],
                        },
                    )
                    return

                if self.path == "/status":
                    self._send_json(200, {"agent": runtime.agent_name, **snapshot})
                    return

                if self.path == "/metrics":
                    rendered = runtime.metrics.render()
                    self.send_response(200)
                    self.send_header("Content-Type", rendered.content_type)
                    self.send_header("Content-Length", str(len(rendered.body)))
                    self.end_headers()
                    self.wfile.write(rendered.body)
                    return

                self._send_json(404, {"error": "not found"})

            def log_message(self, _format: str, *_args: Any) -> None:
                return

        return HealthHandler

    def _start_health_server(self) -> None:
        server = ThreadingHTTPServer(
            ("0.0.0.0", self.health_port),
            self._health_handler(),
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.log("health_server_started", port=self.health_port)

    def _run_subscriber(self) -> None:
        self.streaming_future = self.subscriber.subscribe(
            self.subscription_path,
            callback=self._callback,
            flow_control=self.flow_control,
        )
        self._update_state(subscriber_started=True)
        self.metrics.mark_ready(True)
        self.log(
            "subscriber_started",
            subscription=self.subscription_path,
            output_topic=self.output_topic_path,
        )

        try:
            self.streaming_future.result()
        except Exception as exc:
            if not self.stop_event.is_set():
                self._update_state(subscriber_started=False, last_error=str(exc))
                self.metrics.mark_ready(False)
                self.log("subscriber_failed", error=str(exc))
                raise

    def _handle_signal(self, signum: int, _frame: Any) -> None:
        self.log("shutdown_requested", signal=signum)
        self.stop_event.set()
        self.metrics.mark_ready(False)
        if self.streaming_future is not None:
            self.streaming_future.cancel()

    def run(self) -> None:
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)
        self._start_health_server()
        self.log(
            "agent_started",
            project_id=self.project_id,
            input_subscription=self.input_subscription,
            output_topic=self.output_topic,
        )

        try:
            self._run_subscriber()
        finally:
            self._update_state(subscriber_started=False)
            self.metrics.mark_ready(False)
            self.subscriber.close()
            self.publisher.stop()
            self.log("agent_stopped")


def stable_id(prefix: str, *values: Any) -> str:
    import hashlib

    encoded = json.dumps(values, sort_keys=True, default=str).encode("utf-8")
    return f"{prefix}:{hashlib.sha256(encoded).hexdigest()}"
