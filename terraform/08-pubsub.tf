# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_service
# Enable the Pub/Sub API and create the service agent identity for the project.
resource "google_project_service" "pubsub" {
  project            = var.project_id
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_service_identity
# Ensure the Pub/Sub service agent identity exists for the project.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  depends_on = [google_project_service.pubsub]
}

locals {
  pubsub_service_agent = google_project_service_identity.pubsub.email
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_pubsub_topic
# Existing MCP audit stream.
resource "google_pubsub_topic" "guardian_audit" {
  name = "guardian-audit"

  depends_on = [google_project_service.pubsub]
}

# Raw telemetry ingress. Cloud Logging and optional SCC exports publish here.
resource "google_pubsub_topic" "raw_security_events" {
  name = var.raw_security_events_topic_name

  message_retention_duration = "604800s"

  depends_on = [google_project_service.pubsub]
}

# Dead-letter queue for raw telemetry. Failed messages from the main subscription are sent here.
resource "google_pubsub_topic" "raw_security_events_dlq" {
  name = "${var.raw_security_events_topic_name}-dlq"

  message_retention_duration = "1209600s"

  depends_on = [google_project_service.pubsub]
}

# Normalized findings consumed by the multi-agent workflow.
resource "google_pubsub_topic" "security_findings" {
  name = var.security_findings_topic_name

  message_retention_duration = "604800s"

  depends_on = [google_project_service.pubsub]
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_pubsub_subscription
# Existing MCP audit subscription.
resource "google_pubsub_subscription" "guardian_audit_sub" {
  name                 = "guardian-audit-sub"
  topic                = google_pubsub_topic.guardian_audit.id
  ack_deadline_seconds = 30

  expiration_policy {
    ttl = ""
  }
}

# The raw security events subscription must exist before the DLQ subscription. Otherwise, the DLQ subscription will fail to create.
resource "google_pubsub_subscription" "raw_security_events_dlq_sub" {
  name                 = "${var.raw_security_events_topic_name}-dlq-sub"
  topic                = google_pubsub_topic.raw_security_events_dlq.id
  ack_deadline_seconds = 30

  message_retention_duration = "1209600s"

  expiration_policy {
    ttl = ""
  }
}

# The raw security events subscription. Failed messages are sent to the DLQ.
resource "google_pubsub_subscription" "raw_security_events_sub" {
  name                 = "${var.raw_security_events_topic_name}-sub"
  topic                = google_pubsub_topic.raw_security_events.id
  ack_deadline_seconds = 60

  message_retention_duration = "604800s"
  retain_acked_messages      = false

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.raw_security_events_dlq.id
    max_delivery_attempts = 5
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [
    google_pubsub_topic_iam_member.pubsub_service_agent_dlq_publisher,
  ]
}

# A pull subscription makes lab validation deterministic. Later stages add dedicated agent subscriptions without changing this topic.
resource "google_pubsub_subscription" "security_findings_debug_sub" {
  name                 = "${var.security_findings_topic_name}-debug-sub"
  topic                = google_pubsub_topic.security_findings.id
  ack_deadline_seconds = 30

  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_pubsub_topic_iam_member
# The Pub/Sub service agent must publish failed messages to the DLQ.
resource "google_pubsub_topic_iam_member" "pubsub_service_agent_dlq_publisher" {
  topic  = google_pubsub_topic.raw_security_events_dlq.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${local.pubsub_service_agent}"
}

# The Pub/Sub service agent must forward messages from the source subscription.
resource "google_pubsub_subscription_iam_member" "pubsub_service_agent_raw_subscriber" {
  subscription = google_pubsub_subscription.raw_security_events_sub.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_service_agent}"
}
