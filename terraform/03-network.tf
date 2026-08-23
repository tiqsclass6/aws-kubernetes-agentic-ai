# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service
resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network
resource "google_compute_network" "main" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.compute]
}

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork
# Private GKE nodes; Cloud NAT covers image pulls and Vertex AI. VPC Flow Logs
# satisfy Prowler compute_network_flow_logs / CIS networking checks.
resource "google_compute_subnetwork" "main" {
  name                     = "${var.cluster_name}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "${var.cluster_name}-pods"
    ip_cidr_range = var.gke_secondary_ranges.pods
  }

  secondary_ip_range {
    range_name    = "${var.cluster_name}-services"
    ip_cidr_range = var.gke_secondary_ranges.services
  }
}

resource "google_compute_router" "nat" {
  count = var.enable_private_nodes ? 1 : 0

  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.main.id

  depends_on = [google_project_service.compute]
}

resource "google_compute_router_nat" "nat" {
  count = var.enable_private_nodes ? 1 : 0

  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.nat[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_project_service" "dns" {
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_dns_policy" "logging" {
  name           = "${var.cluster_name}-dns-logging"
  enable_logging = true

  networks {
    network_url = google_compute_network.main.id
  }

  depends_on = [google_project_service.dns]
}
