# -----------------------------------------------------------------------------
# Phase 5 Deterministic Governance Core
# -----------------------------------------------------------------------------

resource "google_service_account" "governance_agent" {
  account_id   = "governance-agent"
  display_name = "Deterministic Governance Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "governance_agent_subscriber" {
  subscription = google_pubsub_subscription.governance_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.governance_agent.email}"
}

resource "google_pubsub_topic_iam_member" "governance_agent_decision_publisher" {
  topic  = google_pubsub_topic.governance_decisions.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.governance_agent.email}"
}

resource "google_pubsub_topic_iam_member" "governance_agent_approval_request_publisher" {
  topic  = google_pubsub_topic.approval_requests.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.governance_agent.email}"
}

resource "google_pubsub_topic_iam_member" "governance_agent_audit_publisher" {
  topic  = google_pubsub_topic.governance_audit.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.governance_agent.email}"
}

resource "google_project_iam_member" "governance_agent_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.governance_agent.email}"
}

resource "google_service_account_iam_member" "governance_agent_workload_identity" {
  service_account_id = google_service_account.governance_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-governance/governance-agent]"

  depends_on = [google_container_cluster.primary]
}

# -----------------------------------------------------------------------------
# Phase 5 cryptographic human-approval verifier
# -----------------------------------------------------------------------------

resource "google_service_account" "approval_agent" {
  account_id   = "approval-agent"
  display_name = "Human Approval Verification Agent Service Account"
}

resource "google_pubsub_subscription_iam_member" "approval_agent_subscriber" {
  subscription = google_pubsub_subscription.approval_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.approval_agent.email}"
}

resource "google_pubsub_topic_iam_member" "approval_agent_decision_publisher" {
  topic  = google_pubsub_topic.governance_decisions.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.approval_agent.email}"
}

resource "google_pubsub_topic_iam_member" "approval_agent_audit_publisher" {
  topic  = google_pubsub_topic.governance_audit.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.approval_agent.email}"
}

resource "google_project_iam_member" "approval_agent_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.approval_agent.email}"
}

resource "google_service_account_iam_member" "approval_agent_workload_identity" {
  service_account_id = google_service_account.approval_agent.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[ai-governance/approval-agent]"

  depends_on = [google_container_cluster.primary]
}

# The remediation executor uses Firestore as an idempotency ledger so a Pub/Sub
# redelivery cannot trigger the same Kubernetes rollout twice.
resource "google_project_iam_member" "remediation_agent_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.remediation_agent.email}"
}

# Human reviewers use the same configured IAM members to pull approval requests,
# publish signed decisions, and use the Cloud KMS signing key.
resource "google_pubsub_subscription_iam_member" "approval_reviewers_subscriber" {
  for_each = toset(var.phase5_approval_signer_members)

  subscription = google_pubsub_subscription.approval_requests_review.name
  role         = "roles/pubsub.subscriber"
  member       = each.value
}

resource "google_pubsub_topic_iam_member" "approval_reviewers_publisher" {
  for_each = toset(var.phase5_approval_signer_members)

  topic  = google_pubsub_topic.approval_decisions.id
  role   = "roles/pubsub.publisher"
  member = each.value
}
