# Expire resolved or abandoned approval requests after their request expiry.
resource "google_firestore_field" "approval_request_expiry" {
  project    = var.project_id
  database   = "(default)"
  collection = "approval_requests"
  field      = "expires_at"

  ttl_config {}
  index_config {}

  depends_on = [
    google_project_service.firestore,
    google_firestore_database.agent_state,
  ]
}

# Retain execution idempotency records long enough to prevent duplicate rollouts,
# then remove them automatically through Firestore TTL.
resource "google_firestore_field" "remediation_execution_expiry" {
  project    = var.project_id
  database   = "(default)"
  collection = "remediation_executions"
  field      = "expires_at"

  ttl_config {}
  index_config {}

  depends_on = [
    google_project_service.firestore,
    google_firestore_database.agent_state,
  ]
}
