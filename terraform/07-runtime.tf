# https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/terraform_data
resource "terraform_data" "update_kubeconfig" {
  count = var.enable_kubeconfig ? 1 : 0

  input = google_container_cluster.primary.id

  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
  }
}
