# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic
# Optional because a student project may not have Security Command Center activated or the required organization/project permissions.
resource "google_project_service" "security_center" {
  count = var.enable_scc_notifications ? 1 : 0

  project            = var.project_id
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/scc_v2_project_notification_config
# Optional because a student project may not have Security Command Center activated or the required organization/project permissions.
resource "google_scc_v2_project_notification_config" "security_findings" {
  count = var.enable_scc_notifications ? 1 : 0

  config_id    = "agentic-security-findings"
  project      = var.project_id
  location     = var.scc_location
  description  = "Active Security Command Center findings for the GKE security platform"
  pubsub_topic = google_pubsub_topic.raw_security_events.id

  streaming_config {
    filter = var.scc_notification_filter
  }

  depends_on = [google_project_service.security_center]
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member
# Optional because a student project may not have Security Command Center activated or the required organization/project permissions.
resource "google_pubsub_topic_iam_member" "scc_notification_publisher" {
  count = var.enable_scc_notifications ? 1 : 0

  topic  = google_pubsub_topic.raw_security_events.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_scc_v2_project_notification_config.security_findings[0].service_account}"
}