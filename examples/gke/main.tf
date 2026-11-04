# Example root: the agent-sandbox prerequisites on an EXISTING GKE Standard
# cluster. Copy this directory, fill in terraform.tfvars, and apply it from a
# machine that can reach the cluster's control plane. It creates no cluster,
# network, or bucket; see docs/install/gke-agent-sandbox.md.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.39.0, < 9.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
  }

  # Configure remote state for a real install, e.g.:
  # backend "gcs" {
  #   bucket = "my-tf-state"
  #   prefix = "reducto/agent-sandbox"
  # }
}

provider "google" {
  project = var.project_id
}

data "google_client_config" "this" {}

data "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.cluster_location
}

provider "kubectl" {
  host                   = "https://${data.google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.this.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  load_config_file       = false
}

module "agent_sandbox" {
  source = "../../modules/agent-sandbox-gke"

  project_id       = var.project_id
  cluster_name     = var.cluster_name
  cluster_location = var.cluster_location

  node_machine_type = var.node_machine_type
  node_min_count    = var.node_min_count
  node_max_count    = var.node_max_count
  sandbox_pod_range = var.sandbox_pod_range

  node_service_account_extra_roles = var.node_service_account_extra_roles

  bucket_name                 = var.bucket_name
  reducto_namespace           = var.reducto_namespace
  worker_service_account_name = var.worker_service_account_name
}
