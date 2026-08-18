resource "google_project_service" "bigquery" {
  project            = var.project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "governance_evidence_admin" {
  project      = var.project_id
  account_id   = "evidence-admin"
  display_name = "Governance Evidence Administrator"
  description  = "Organization-permitted identity used to own the BigQuery evidence dataset."
}

resource "google_bigquery_dataset" "governance_evidence" {
  project                     = var.project_id
  dataset_id                  = var.evidence_dataset_id
  friendly_name               = "Agentic Governance Evidence"
  description                 = "Structured GKE governance, approval, remediation, and MCP audit logs for the student lab"
  location                    = var.region
  delete_contents_on_destroy  = true
  default_table_expiration_ms = var.evidence_retention_days * 24 * 60 * 60 * 1000

  labels = {
    environment = "lab"
    purpose     = "governance-evidence"
  }

  # Create-time ACL must be only an org-permitted identity. Default projectOwners
  # includes consumer Google accounts and trips iam.allowedPolicyMemberDomains.
  access {
    role       = "OWNER"
    iam_member = "serviceAccount:${google_service_account.governance_evidence_admin.email}"
  }

  lifecycle {
    ignore_changes = [access]
  }

  depends_on = [google_project_service.bigquery]
}

resource "google_logging_project_sink" "governance_evidence" {
  project                = var.project_id
  name                   = "governance-evidence"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.governance_evidence.dataset_id}"
  unique_writer_identity = true

  filter = <<-EOT
    resource.type="k8s_container"
    (
      jsonPayload.component="governance-agent" OR
      jsonPayload.component="approval-agent" OR
      jsonPayload.component="remediation-agent" OR
      jsonPayload.component="mcp-server"
    )
  EOT
}

resource "google_bigquery_dataset_access" "governance_sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.governance_evidence.dataset_id
  role       = "WRITER"
  iam_member = google_logging_project_sink.governance_evidence.writer_identity
}

resource "google_monitoring_alert_policy" "approval_request_backlog" {
  project      = var.project_id
  display_name = "Remediation approval waiting for review"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = "One or more signed-remediation approval requests are waiting. Pull approval-requests-review-sub and review the request before it expires."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Pending approval request detected"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id = \"approval-requests-review-sub\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.approval_backlog_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.monitoring_notification_channel_ids
  depends_on            = [google_project_service.monitoring]
}
