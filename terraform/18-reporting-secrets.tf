resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service_identity" "secretmanager" {
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"

  depends_on = [google_project_service.secretmanager]
}

resource "google_kms_crypto_key_iam_member" "secretmanager_cmek" {
  crypto_key_id = google_kms_crypto_key.lab_cmek.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secretmanager.email}"
}

resource "google_pubsub_topic" "secret_rotation" {
  name = "agentic-secret-rotation"

  depends_on = [google_project_service.pubsub]
}

resource "google_pubsub_topic_iam_member" "secretmanager_rotation_publisher" {
  topic  = google_pubsub_topic.secret_rotation.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_project_service_identity.secretmanager.email}"
}

resource "google_secret_manager_secret" "slack_webhook_url" {
  count = var.create_reporting_secret_containers ? 1 : 0

  project   = var.project_id
  secret_id = var.slack_webhook_secret_id

  replication {
    user_managed {
      replicas {
        location = var.region

        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.lab_cmek.id
        }
      }
    }
  }

  rotation {
    rotation_period    = "7776000s"
    next_rotation_time = "2026-11-18T00:00:00Z"
  }

  topics {
    name = google_pubsub_topic.secret_rotation.id
  }

  lifecycle {
    ignore_changes = [rotation[0].next_rotation_time]
  }

  depends_on = [
    google_project_service.secretmanager,
    google_kms_crypto_key_iam_member.secretmanager_cmek,
    google_pubsub_topic_iam_member.secretmanager_rotation_publisher,
    terraform_data.lab_cmek_primary,
  ]
}

resource "google_secret_manager_secret" "jira_api_token" {
  count = var.create_reporting_secret_containers ? 1 : 0

  project   = var.project_id
  secret_id = var.jira_api_token_secret_id

  replication {
    user_managed {
      replicas {
        location = var.region

        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.lab_cmek.id
        }
      }
    }
  }

  rotation {
    rotation_period    = "7776000s"
    next_rotation_time = "2026-11-18T00:00:00Z"
  }

  topics {
    name = google_pubsub_topic.secret_rotation.id
  }

  lifecycle {
    ignore_changes = [rotation[0].next_rotation_time]
  }

  depends_on = [
    google_project_service.secretmanager,
    google_kms_crypto_key_iam_member.secretmanager_cmek,
    google_pubsub_topic_iam_member.secretmanager_rotation_publisher,
    terraform_data.lab_cmek_primary,
  ]
}

locals {
  reporting_slack_secret_id = (
    var.create_reporting_secret_containers
    ? google_secret_manager_secret.slack_webhook_url[0].secret_id
    : var.slack_webhook_secret_id
  )

  reporting_jira_secret_id = (
    var.create_reporting_secret_containers
    ? google_secret_manager_secret.jira_api_token[0].secret_id
    : var.jira_api_token_secret_id
  )
}