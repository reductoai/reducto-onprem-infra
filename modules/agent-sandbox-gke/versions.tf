terraform {
  # check blocks and data-source postconditions.
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # 7.22.0: node_config.sandbox_config (with `type`) is GA.
      # 7.39.0: addons_config.agent_sandbox_config is GA (read by the
      # cluster postcondition that refuses the GKE-managed v1alpha1 add-on).
      version = ">= 7.39.0, < 9.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0"
    }
  }
}
