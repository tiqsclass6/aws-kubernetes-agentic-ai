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

# Public-control-plane, private-node, VPC-native zonal GKE cluster with Workload Identity.
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

  # GKE still creates one throwaway default-pool VM, then deletes it. The API
  # default is e2-medium, which stocked out in us-central1-c and left Terraform
  # sitting on Still creating... Use the same SKU as the real node pool.
  node_config {
    machine_type    = var.node_machine_type
    disk_size_gb    = var.node_disk_size_gb
    disk_type       = var.node_disk_type
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # GKE rejects reserved instance-metadata keys here. enable-oslogin is
    # also reserved on node pools; OS Login stays at project metadata.
    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

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

  enable_shielded_nodes = true

  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    }
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

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.container,
    google_compute_router_nat.nat,
  ]
}
