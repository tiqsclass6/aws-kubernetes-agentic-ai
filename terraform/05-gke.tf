# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service
resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

data "http" "my_ip" {
  count = var.detect_runner_ip ? 1 : 0
  url   = "https://api.ipify.org"
}

locals {
  current_public_ip_cidr = var.detect_runner_ip ? "${trimspace(data.http.my_ip[0].response_body)}/32" : null

  authorized_networks_all = concat(
    var.authorized_networks,
    local.current_public_ip_cidr != null ? [{
      cidr_block   = local.current_public_ip_cidr
      display_name = "terraform-runner"
    }] : []
  )
}

# Public-control-plane, VPC-native zonal GKE cluster with Workload Identity.
# Dataplane V2 (ADVANCED_DATAPATH) enforces networking.k8s.io/v1 NetworkPolicy.
# Calico cannot be combined with Dataplane V2 and puts the node pool in ERROR
# on current REGULAR-channel GKE.
resource "google_container_cluster" "primary" {
  provider = google-beta

  name                     = var.cluster_name
  location                 = var.zone
  network                  = google_compute_network.main.id
  subnetwork               = google_compute_subnetwork.main.name
  networking_mode          = "VPC_NATIVE"
  datapath_provider        = "ADVANCED_DATAPATH"
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "${var.cluster_name}-pods"
    services_secondary_range_name = "${var.cluster_name}-services"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = local.authorized_networks_all
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  addons_config {
    http_load_balancing {
      disabled = true
    }

    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
    ]
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
      "HPA",
      "POD",
      "DEPLOYMENT",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  deletion_protection = false

  depends_on = [
    google_project_service.compute,
    google_project_service.container
  ]
}
