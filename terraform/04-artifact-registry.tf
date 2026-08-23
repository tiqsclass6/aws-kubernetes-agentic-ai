# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service
resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository
# Docker images for this lab. Build and push with scripts/04-build-images.sh
# or the Governed Release workflow, not gcr.io.
resource "google_artifact_registry_repository" "vertex_agent" {
  provider = google-beta

  location      = var.region
  repository_id = var.artifact_registry_repository_id
  description   = "Container images for ${var.cluster_name}"
  format        = var.artifact_registry_format

  depends_on = [google_project_service.artifactregistry]
}

resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.vertex_agent.location
  repository = google_artifact_registry_repository.vertex_agent.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes.email}"
}
