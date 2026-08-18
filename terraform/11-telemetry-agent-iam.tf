# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_service
# Enable the IAM API so that we can create service accounts and assign roles to them.
resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

# Event Aggregator service account. This service account is used by the GKE workload identity to access GCP resources.
resource "google_service_account" "event_aggregator" {
  account_id   = "event-aggregator"
  display_name = "Security Event Aggregator"
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_pubsub_subscription_iam_member
# The Event Aggregator service account must subscribe to the raw security events subscription.
resource "google_pubsub_subscription_iam_member" "event_aggregator_raw_subscriber" {
  subscription = google_pubsub_subscription.raw_security_events_sub.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.event_aggregator.email}"
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_pubsub_topic_iam_member
# The Event Aggregator service account must publish normalized findings to the security findings topic.
resource "google_pubsub_topic_iam_member" "event_aggregator_findings_publisher" {
  topic  = google_pubsub_topic.security_findings.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.event_aggregator.email}"
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_service_account_iam_member
# The Event Aggregator service account must be able to impersonate the GKE workload identity service account.
resource "google_service_account_iam_member" "event_aggregator_workload_identity" {
  service_account_id = google_service_account.event_aggregator.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[shared-services/event-aggregator]"

  depends_on = [google_container_cluster.primary]
}

# Trivy Artifact Registry scanner service account. This service account is used by the GKE workload identity to access GCP resources.
resource "google_service_account" "trivy" {
  account_id   = "trivy-scanner"
  display_name = "Trivy Artifact Registry Scanner"
}

# Reader role on the Artifact Registry repository is required for Trivy to scan container images.
resource "google_artifact_registry_repository_iam_member" "trivy_reader" {
  location   = google_artifact_registry_repository.vertex_agent.location
  repository = google_artifact_registry_repository.vertex_agent.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.trivy.email}"
}

# Workload identity binding for the Trivy Artifact Registry scanner service account. This allows the GKE workload identity to impersonate the Trivy service account.
resource "google_service_account_iam_member" "trivy_workload_identity" {
  service_account_id = google_service_account.trivy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[security/trivy-ksa]"

  depends_on = [google_container_cluster.primary]
}

# Prowler service account
resource "google_service_account" "prowler" {
  account_id   = "prowler-sa"
  display_name = "Prowler GCP Security Scanner"
}

# Prowler needs storage.buckets.getIamPolicy, which is not in roles/viewer.
# Custom role IDs stay reserved for ~7 days after destroy, so this id is versioned
# to survive destroy/apply cycles (prowlerStorageIamViewer is deletion-pending).
resource "google_project_iam_custom_role" "prowler_storage_iam_viewer" {
  role_id     = "prowlerStorageIamViewerV2"
  title       = "Prowler Storage IAM Viewer"
  description = "Allows Prowler to inspect Cloud Storage bucket IAM policies"
  permissions = ["storage.buckets.getIamPolicy"]
  stage       = "GA"

  depends_on = [google_project_service.iam]
}

# Prowler requires the following roles to scan GCP resources. The predefined roles are sufficient for Prowler to scan GCP resources.
resource "google_project_iam_member" "prowler_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.prowler.email}"
}

# Prowler requires the following roles to scan GCP resources. The predefined roles are sufficient for Prowler to scan GCP resources.
resource "google_project_iam_member" "prowler_service_usage_consumer" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.prowler.email}"
}

# Prowler custom role is required because Prowler needs to inspect Cloud Storage bucket IAM policies, which is not included in the predefined roles.
resource "google_project_iam_member" "prowler_storage_iam_viewer" {
  project = var.project_id
  role    = google_project_iam_custom_role.prowler_storage_iam_viewer.name
  member  = "serviceAccount:${google_service_account.prowler.email}"
}

# Prowler workload identity binding. This allows the GKE workload identity to impersonate the Prowler service account.
resource "google_service_account_iam_member" "prowler_workload_identity" {
  service_account_id = google_service_account.prowler.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[security/prowler-ksa]"

  depends_on = [google_container_cluster.primary]
}