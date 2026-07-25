resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "slack_webhook_url" {
  count = var.create_reporting_secret_containers ? 1 : 0

  project   = var.project_id
  secret_id = var.slack_webhook_secret_id

  replication {
    auto {}
  }

  depends_on = [
    google_project_service.secretmanager,
  ]
}

resource "google_secret_manager_secret" "jira_api_token" {
  count = var.create_reporting_secret_containers ? 1 : 0

  project   = var.project_id
  secret_id = var.jira_api_token_secret_id

  replication {
    auto {}
  }

  depends_on = [
    google_project_service.secretmanager,
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