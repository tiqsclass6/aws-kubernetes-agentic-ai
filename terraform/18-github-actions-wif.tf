data "google_project" "github_actions" {
  project_id = var.project_id
}

resource "google_iam_workload_identity_pool" "github_actions" {
  project                   = var.project_id
  workload_identity_pool_id = var.github_wif_pool_id
  display_name              = "GitHub Actions"
  description               = "Keyless OIDC federation for the agentic security release workflow"
}

resource "google_iam_workload_identity_pool_provider" "github_actions" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = var.github_wif_provider_id
  display_name                       = "GitHub repository provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.workflow"   = "assertion.workflow"
  }

  attribute_condition = "assertion.repository == '${var.github_owner}/${var.github_repository}' && assertion.ref == 'refs/heads/${var.github_default_branch}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_release" {
  project      = var.project_id
  account_id   = "github-release"
  display_name = "GitHub Release Pipeline"
  description  = "Short-lived release identity for Artifact Registry and GKE deployment"
}

resource "google_service_account_iam_member" "github_release_federation" {
  service_account_id = google_service_account.github_release.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "principalSet://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s/attribute.repository/%s/%s",
    data.google_project.github_actions.number,
    google_iam_workload_identity_pool.github_actions.workload_identity_pool_id,
    var.github_owner,
    var.github_repository,
  )
}

resource "google_artifact_registry_repository_iam_member" "github_release_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.vertex_agent.location
  repository = google_artifact_registry_repository.vertex_agent.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_release.email}"
}

resource "google_project_iam_member" "github_release_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.github_release.email}"
}

# Kubernetes object permissions are granted by namespaced RBAC in
# manifests/rbac/github-release-deployer.yaml. The release identity receives
# only cluster discovery at the Google Cloud IAM layer.
