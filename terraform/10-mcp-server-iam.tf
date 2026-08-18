# The previous standalone guardian agent is retired. MCP audit events
# are published both to guardian-audit for audit retention and to
# raw-security-events so the live Observer -> Correlation -> IR pipeline
# receives them.

resource "google_service_account" "mcp_server" {
  account_id   = "mcp-server"
  display_name = "MCP Server Service Account"
}

resource "google_pubsub_topic_iam_member" "mcp_server_guardian_audit_publisher" {
  topic  = google_pubsub_topic.guardian_audit.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.mcp_server.email}"
}

resource "google_pubsub_topic_iam_member" "mcp_server_raw_security_events_publisher" {
  topic  = google_pubsub_topic.raw_security_events.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.mcp_server.email}"
}

resource "google_service_account_iam_member" "mcp_server_workload_identity" {
  service_account_id = google_service_account.mcp_server.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[mcp/mcp-server-sa]"

  depends_on = [
    google_container_cluster.primary,
  ]
}