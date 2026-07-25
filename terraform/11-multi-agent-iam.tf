# -----------------------------------------------------------------------------
# Correlation Agent
# -----------------------------------------------------------------------------

resource "google_service_account" "correlation_agent" {
  account_id   = "correlation-agent"
  display_name = "Correlation Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "correlation_agent_subscriber" {
  subscription = google_pubsub_subscription.correlation_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.correlation_agent.email}"
}

resource "google_pubsub_topic_iam_member" "correlation_agent_publisher" {
  topic  = google_pubsub_topic.correlated_incidents.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.correlation_agent.email}"
}

resource "google_project_iam_member" "correlation_agent_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.correlation_agent.email}"
}

resource "google_service_account_iam_member" "correlation_agent_workload_identity" {
  service_account_id = google_service_account.correlation_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-agents/correlation-agent]"

  depends_on = [
    google_container_cluster.primary,
  ]
}

# -----------------------------------------------------------------------------
# Remediation Agent
# -----------------------------------------------------------------------------

resource "google_service_account" "remediation_agent" {
  account_id   = "remediation-agent"
  display_name = "Remediation Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "remediation_agent_subscriber" {
  subscription = google_pubsub_subscription.remediation_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.remediation_agent.email}"
}

resource "google_pubsub_topic_iam_member" "remediation_agent_publisher" {
  topic  = google_pubsub_topic.remediation_results.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.remediation_agent.email}"
}

resource "google_service_account_iam_member" "remediation_agent_workload_identity" {
  service_account_id = google_service_account.remediation_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-agents/remediation-agent]"

  depends_on = [
    google_container_cluster.primary,
  ]
}

# -----------------------------------------------------------------------------
# Reporting Agent
# -----------------------------------------------------------------------------

resource "google_service_account" "reporting_agent" {
  account_id   = "reporting-agent"
  display_name = "Reporting Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "reporting_agent_subscriber" {
  subscription = google_pubsub_subscription.reporting_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.reporting_agent.email}"
}

resource "google_pubsub_topic_iam_member" "reporting_agent_publisher" {
  topic  = google_pubsub_topic.incident_reports.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.reporting_agent.email}"
}

resource "google_secret_manager_secret_iam_member" "reporting_agent_slack_accessor" {
  project   = var.project_id
  secret_id = local.reporting_slack_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.reporting_agent.email}"
}

resource "google_secret_manager_secret_iam_member" "reporting_agent_jira_accessor" {
  project   = var.project_id
  secret_id = local.reporting_jira_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.reporting_agent.email}"
}

resource "google_service_account_iam_member" "reporting_agent_workload_identity" {
  service_account_id = google_service_account.reporting_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-agents/reporting-agent]"

  depends_on = [
    google_container_cluster.primary,
  ]
}