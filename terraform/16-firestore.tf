resource "google_project_service" "firestore" {
  project            = var.project_id
  service            = "firestore.googleapis.com"
  disable_on_destroy = false
}

resource "google_firestore_database" "agent_state" {
  count = var.manage_firestore_database ? 1 : 0

  project                     = var.project_id
  name                        = "(default)"
  location_id                 = var.firestore_location
  type                        = "FIRESTORE_NATIVE"
  concurrency_mode            = "OPTIMISTIC"
  app_engine_integration_mode = "DISABLED"
  deletion_policy             = "DELETE"

  depends_on = [
    google_project_service.firestore,
  ]
}

# Expire correlation-window state after the timestamp written to expires_at.
# index_config {} disables unnecessary single-field indexes on this TTL field.
resource "google_firestore_field" "correlation_window_expiry" {
  project    = var.project_id
  database   = "(default)"
  collection = "correlation_windows"
  field      = "expires_at"

  ttl_config {}

  index_config {}

  depends_on = [
    google_project_service.firestore,
    google_firestore_database.agent_state,
  ]
}