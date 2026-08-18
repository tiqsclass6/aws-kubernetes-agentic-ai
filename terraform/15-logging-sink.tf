# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/logging_project_sink
# Route selected GKE warnings/errors and security-sensitive Admin Activity audit logs into the raw telemetry topic.
resource "google_logging_project_sink" "security_events" {
  name = "agentic-security-events"

  destination = "pubsub.googleapis.com/${google_pubsub_topic.raw_security_events.id}"

  filter = <<-EOT
    (
      resource.type="k8s_container"
      AND
      (
        resource.labels.namespace_name="app01"
        OR resource.labels.namespace_name="security"
        OR resource.labels.namespace_name="ai-agents"
        OR resource.labels.namespace_name="mcp"
        OR resource.labels.namespace_name="mcp-gateway"
        OR resource.labels.namespace_name="shared-services"
      )
      AND severity>=WARNING
    )
    OR
    (
      resource.type="k8s_cluster"
      AND log_id("events")
      AND severity>=WARNING
    )
    OR
    (
      log_id("cloudaudit.googleapis.com/activity")
      AND
      (
        protoPayload.serviceName="container.googleapis.com"
        OR protoPayload.serviceName="iam.googleapis.com"
        OR protoPayload.serviceName="artifactregistry.googleapis.com"
      )
    )
  EOT

  unique_writer_identity = true

  depends_on = [google_project_service.logging]
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member
# Grant the logging sink's service account the Pub/Sub Publisher role on the raw telemetry topic.
resource "google_pubsub_topic_iam_member" "logging_sink_publisher" {
  topic  = google_pubsub_topic.raw_security_events.id
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.security_events.writer_identity
}