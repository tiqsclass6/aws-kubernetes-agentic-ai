terraform {
  required_version = ">= 1.10.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }

  backend "gcs" {
    bucket = "tiqs-kubernetes"
    prefix = "agentic/terraform/state"
  }
}

provider "google" {
  project        = var.project_id
  region         = var.region
  credentials    = var.gcp_credentials_file != "" ? file(var.gcp_credentials_file) : null
  default_labels = local.common_labels
}

provider "google-beta" {
  project        = var.project_id
  region         = var.region
  credentials    = var.gcp_credentials_file != "" ? file(var.gcp_credentials_file) : null
  default_labels = local.common_labels
}
