# Project-level CIS / Prowler remediations that this lab owns. Prowler still
# scans the rest of class-6-5-tiqs (default VPC, other class buckets/VMs).

resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_project_metadata_item" "os_login" {
  project = var.project_id
  key     = "enable-oslogin"
  value   = "TRUE"

  depends_on = [google_project_service.compute]
}

resource "google_compute_project_metadata_item" "serial_port" {
  project = var.project_id
  key     = "serial-port-enable"
  value   = "FALSE"

  depends_on = [google_project_service.compute]
}

resource "google_compute_project_metadata_item" "block_project_ssh_keys" {
  project = var.project_id
  key     = "block-project-ssh-keys"
  value   = "TRUE"

  depends_on = [google_project_service.compute]
}

resource "google_project_iam_audit_config" "all_services" {
  project = var.project_id
  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# Prowler logging_sink_created requires a sink whose filter is omitted/"all".
resource "google_storage_bucket" "audit_logs" {
  project                     = var.project_id
  name                        = "${var.project_id}-agentic-audit-logs"
  location                    = var.region
  force_destroy               = true
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.lab_cmek.id
  }

  lifecycle_rule {
    condition {
      age = var.evidence_retention_days
    }
    action {
      type = "Delete"
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [
    google_project_service.storage,
    google_kms_crypto_key_iam_member.lab_cmek_encrypters,
    terraform_data.lab_cmek_primary,
  ]
}

resource "google_logging_project_sink" "all_logs" {
  project                = var.project_id
  name                   = "agentic-all-logs"
  destination            = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"
  unique_writer_identity = true

  depends_on = [google_project_service.logging]
}

resource "google_storage_bucket_iam_member" "all_logs_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.all_logs.writer_identity
}

# Filter strings must contain the exact Prowler CIS substrings.
# alert_resource_type is the Cloud Monitoring resource (not always the
# Logging resource). iam_role / gce_firewall_rule / gce_route / gce_network
# map to global for log-based metrics.
locals {
  cis_log_metrics = {
    project-ownership = {
      filter              = "(protoPayload.serviceName=\"cloudresourcemanager.googleapis.com\") AND (ProjectOwnership OR projectOwnerInvitee) OR (protoPayload.serviceData.policyDelta.bindingDeltas.action=\"REMOVE\" AND protoPayload.serviceData.policyDelta.bindingDeltas.role=\"roles/owner\") OR (protoPayload.serviceData.policyDelta.bindingDeltas.action=\"ADD\" AND protoPayload.serviceData.policyDelta.bindingDeltas.role=\"roles/owner\")"
      alert_resource_type = "global"
    }
    audit-config = {
      filter              = "protoPayload.methodName=\"SetIamPolicy\" AND protoPayload.serviceData.policyDelta.auditConfigDeltas:*"
      alert_resource_type = "global"
    }
    custom-role = {
      filter              = "resource.type=\"iam_role\" AND (protoPayload.methodName=\"google.iam.admin.v1.CreateRole\" OR protoPayload.methodName=\"google.iam.admin.v1.DeleteRole\" OR protoPayload.methodName=\"google.iam.admin.v1.UpdateRole\")"
      alert_resource_type = "global"
    }
    vpc-firewall = {
      filter              = "resource.type=\"gce_firewall_rule\" AND (protoPayload.methodName:\"compute.firewalls.patch\" OR protoPayload.methodName:\"compute.firewalls.insert\" OR protoPayload.methodName:\"compute.firewalls.delete\")"
      alert_resource_type = "global"
    }
    vpc-route = {
      filter              = "resource.type=\"gce_route\" AND (protoPayload.methodName:\"compute.routes.delete\" OR protoPayload.methodName:\"compute.routes.insert\")"
      alert_resource_type = "global"
    }
    vpc-network = {
      filter              = "resource.type=\"gce_network\" AND (protoPayload.methodName:\"compute.networks.insert\" OR protoPayload.methodName:\"compute.networks.patch\" OR protoPayload.methodName:\"compute.networks.delete\" OR protoPayload.methodName:\"compute.networks.removePeering\" OR protoPayload.methodName:\"compute.networks.addPeering\")"
      alert_resource_type = "global"
    }
    bucket-iam = {
      filter              = "resource.type=\"gcs_bucket\" AND protoPayload.methodName=\"storage.setIamPermissions\""
      alert_resource_type = "gcs_bucket"
    }
    sql-config = {
      filter              = "protoPayload.methodName=\"cloudsql.instances.update\""
      alert_resource_type = "cloudsql_database"
    }
    compute-config = {
      filter              = "protoPayload.serviceName=\"compute.googleapis.com\""
      alert_resource_type = "global"
    }
  }
}

resource "google_logging_metric" "cis" {
  for_each = local.cis_log_metrics

  project = var.project_id
  name    = "cis-${each.key}"
  filter  = each.value.filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.logging]
}

resource "google_monitoring_alert_policy" "cis" {
  for_each = local.cis_log_metrics

  project      = var.project_id
  display_name = "CIS log metric ${each.key}"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = "Prowler/CIS requires a Cloud Monitoring alert on log metric cis-${each.key}."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "cis-${each.key} above zero"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.cis[each.key].name}\" AND resource.type=\"${each.value.alert_resource_type}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_DELTA"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.monitoring_notification_channel_ids
  depends_on            = [google_project_service.monitoring]
}
