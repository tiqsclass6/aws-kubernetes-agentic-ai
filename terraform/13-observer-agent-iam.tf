resource "google_service_account" "observer_agent" {
  account_id   = "observer-agent"
  display_name = "Observer Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "observer_agent_subscriber" {
  subscription = google_pubsub_subscription.observer_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.observer_agent.email}"
}

resource "google_pubsub_topic_iam_member" "observer_agent_publisher" {
  topic  = google_pubsub_topic.observed_findings.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.observer_agent.email}"
}

resource "google_service_account_iam_member" "observer_agent_workload_identity" {
  service_account_id = google_service_account.observer_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-agents/observer-agent]"

  depends_on = [
    google_container_cluster.primary,
  ]
}