# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service
resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository
# Repo for the vertex-agent image. gcr.io (used by the original walkthru.md) is
# deprecated for new projects - build/push here instead:
#   gcloud builds submit --tag us-central1-docker.pkg.dev/PROJECT_ID/vertex-agent-lab/vertex-agent:lab1a
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
