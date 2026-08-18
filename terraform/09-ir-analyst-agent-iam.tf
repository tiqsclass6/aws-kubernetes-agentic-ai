resource "google_project_service" "vertex_ai" {
  project            = var.project_id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "logging" {
  project            = var.project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iamcredentials" {
  project            = var.project_id
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sts" {
  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

# Preserve the existing Terraform resource address to avoid replacing the GSA.
resource "google_service_account" "vertex_agent" {
  account_id   = "vertex-gke-agent"
  display_name = "IR Analyst Agent Service Account"
}

resource "google_project_iam_member" "vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.vertex_agent.email}"
}

resource "google_pubsub_subscription_iam_member" "ir_analyst_subscriber" {
  subscription = google_pubsub_subscription.ir_analyst_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.vertex_agent.email}"
}

resource "google_pubsub_topic_iam_member" "ir_analyst_publisher" {
  topic  = google_pubsub_topic.analyzed_incidents.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.vertex_agent.email}"
}

resource "google_service_account_iam_member" "vertex_agent_workload_identity" {
  service_account_id = google_service_account.vertex_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-agents/ir-analyst-agent]"

  depends_on = [
    google_container_cluster.primary,
  ]
}