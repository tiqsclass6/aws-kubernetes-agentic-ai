# Project / Authentication

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for resource deployment"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the (zonal) GKE cluster"
  type        = string
  default     = "us-central1-a"
}

variable "gcp_credentials_file" {
  description = "Path to a GCP service account .json key file. Leave blank to use Application Default Credentials (gcloud auth application-default login) instead."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "vertex-agent-lab"
  nullable    = false
}

variable "enable_kubeconfig" {
  description = "Set to false to skip local kubeconfig update on apply"
  type        = bool
  default     = true
}

# VPC / subnet

variable "vpc_cidr" {
  description = "CIDR block for the VPC network"
  type        = string
  default     = "10.110.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the single GKE subnet"
  type        = string
  default     = "10.110.0.0/20"
}

variable "gke_secondary_ranges" {
  description = "Secondary CIDR ranges used by GKE pods and services"
  type = object({
    pods     = string
    services = string
  })
  default = {
    pods     = "10.111.0.0/16"
    services = "10.112.0.0/20"
  }
}

# Control-plane access

variable "detect_runner_ip" {
  description = "Auto-detect the Terraform runner's public IP via an external HTTP call and add it to authorized_networks. Known to fail on this machine (Windows/schannel cert-revocation check blocks the Go HTTP client, same gotcha documented in project-8's RUNBOOK) - leave false and set authorized_networks manually instead."
  type        = bool
  default     = false
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the public GKE control-plane endpoint."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# Artifact Registry

variable "artifact_registry_repository_id" {
  description = "Artifact Registry repository ID for the vertex-agent image"
  type        = string
  default     = "vertex-agent-lab"
}

variable "artifact_registry_format" {
  description = "Artifact Registry repository format"
  type        = string
  default     = "DOCKER"
}

# Node pool - sized for the full agent fleet (vertex-agent, mcp-server, observer-agent,
# mcp-gateway nginx, mcp-guardian-agent as steady-state Deployments, plus the ai-soc/
# ai-ops/cert-guardian Jobs running transiently on top). A single e2-standard-2
# (1930m allocatable) got to ~1700m/1930m with everything deployed at once - too
# little headroom for a Job to schedule without evicting something. 2x n2-standard-2
# roughly doubles total allocatable CPU without jumping to an oversized machine type.

variable "node_machine_type" {
  description = <<-EOT
    Machine type for the GKE worker nodes. Must be a dedicated-core (standard/highmem/
    highcpu) type, not a shared-core type (e2-micro/e2-small/e2-medium) - confirmed live
    that e2-medium's small allocatable CPU (940m of its 2 vCPU capacity) is entirely
    eaten by GKE's own managed logging/monitoring/metrics daemonsets (~851m), leaving
    no room even for broken-app's 100m request. n2-standard-2 is dedicated-core (same
    reasoning as the earlier e2-standard-2 fix) and a newer generation with better
    price/performance; confirmed live that e2-standard-2 alone still ran short once
    the full agent fleet was deployed simultaneously.
  EOT
  type        = string
  default     = "n2-standard-2"
}

variable "node_disk_size_gb" {
  description = "Boot disk size in GB for each GKE node"
  type        = number
  default     = 30
}

variable "node_disk_type" {
  description = "Boot disk type for the GKE nodes"
  type        = string
  default     = "pd-balanced"
}

variable "node_count" {
  description = "Fixed node count (no autoscaling needed for this lab's footprint). 2 nodes: confirmed live that 1 node left too little headroom once the full agent fleet plus any Job (ai-soc pipeline, cert-guardian, operational-readiness) tried to schedule at the same time."
  type        = number
  default     = 2
}

locals {
  workload_pool = "${var.project_id}.svc.id.goog"

  common_labels = {
    cluster = var.cluster_name
    managed = "terraform"
  }
}


variable "raw_security_events_topic_name" {
  description = "Pub/Sub topic receiving raw security telemetry from Cloud Logging and Security Command Center"
  type        = string
  default     = "raw-security-events"
}

variable "security_findings_topic_name" {
  description = "Pub/Sub topic receiving normalized security findings from the event aggregator"
  type        = string
  default     = "security-findings"
}

variable "enable_scc_notifications" {
  description = "Create a Security Command Center v2 notification configuration. Requires SCC to be activated and the Terraform principal to have SCC administration permissions."
  type        = bool
  default     = false
}

variable "scc_location" {
  description = "Security Command Center data-residency location. Use global unless SCC data residency is enabled."
  type        = string
  default     = "global"

  validation {
    condition     = contains(["global", "us", "eu", "sa"], var.scc_location)
    error_message = "scc_location must be one of global, us, eu, or sa."
  }
}

variable "scc_notification_filter" {
  description = "Security Command Center findings filter used by the continuous Pub/Sub export"
  type        = string
  default     = "state = \"ACTIVE\""
}

variable "manage_firestore_database" {
  description = "Create the default Firestore Native database used for durable correlation state. Set false when the project already has a default Firestore database."
  type        = bool
  default     = true
}

variable "firestore_location" {
  description = "Firestore database location for the correlation agent state"
  type        = string
  default     = "us-central1"
}

variable "create_reporting_secret_containers" {
  description = "Create Secret Manager containers for the optional Slack webhook and Jira API token. Secret values are added separately and are never stored in Terraform."
  type        = bool
  default     = true
}

variable "slack_webhook_secret_id" {
  description = "Secret Manager secret ID containing the optional Slack incoming webhook URL"
  type        = string
  default     = "security-slack-webhook-url"
}

variable "jira_api_token_secret_id" {
  description = "Secret Manager secret ID containing the optional Jira API token"
  type        = string
  default     = "security-jira-api-token"
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository"
  type        = string
  default     = "tiqsclass6"
}

variable "github_repository" {
  description = "GitHub repository name trusted by the Phase 4 release identity"
  type        = string
  default     = "agentic-security-lab"
}

variable "github_default_branch" {
  description = "Default branch permitted to run the production release workflow"
  type        = string
  default     = "main"
}

variable "github_wif_pool_id" {
  description = "Workload Identity Pool ID used by GitHub Actions"
  type        = string
  default     = "github-actions"
}

variable "github_wif_provider_id" {
  description = "OIDC provider ID inside the GitHub Actions workload identity pool"
  type        = string
  default     = "github"
}

variable "monitoring_notification_channel_ids" {
  description = "Existing Cloud Monitoring notification channel resource names"
  type        = list(string)
  default     = []
}

variable "pipeline_backlog_threshold" {
  description = "Undelivered Pub/Sub messages that trigger the Phase 4 backlog alert"
  type        = number
  default     = 100
}

variable "pipeline_oldest_message_threshold_seconds" {
  description = "Maximum acceptable age of the oldest unacknowledged pipeline message"
  type        = number
  default     = 300
}

# Phase 5 governance, approval, and evidence

variable "phase5_policy_id" {
  description = "Policy identifier accepted by the Phase 5 governance and remediation agents"
  type        = string
  default     = "phase5-remediation"
}

variable "phase5_approval_signer_members" {
  description = "IAM members allowed to review approval requests, publish decisions, and use the approval signing key. Example: [\"user:analyst@example.com\"]"
  type        = list(string)
  default     = []
}

variable "phase5_kms_keyring_id" {
  description = "Cloud KMS key ring used for cryptographically signed remediation approvals"
  type        = string
  default     = "agentic-governance"
}

variable "phase5_approval_key_id" {
  description = "Cloud KMS asymmetric signing key used for human approval decisions"
  type        = string
  default     = "approval-signing"
}

variable "phase5_approval_key_version" {
  description = "Enabled Cloud KMS key version used by the approval review script and approval agent"
  type        = string
  default     = "1"
}

variable "phase5_evidence_dataset_id" {
  description = "BigQuery dataset that receives governance and remediation audit logs"
  type        = string
  default     = "agentic_governance_evidence"
}

variable "phase5_evidence_retention_days" {
  description = "Default BigQuery table retention for Phase 5 governance evidence"
  type        = number
  default     = 90
}

variable "phase5_approval_backlog_threshold" {
  description = "Pending approval requests that trigger the Phase 5 review backlog alert"
  type        = number
  default     = 0
}
