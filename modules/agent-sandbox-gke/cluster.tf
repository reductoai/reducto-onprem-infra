# The existing GKE Standard cluster. Every resource in this module reads it, so
# the postconditions below gate the whole apply: a cluster that cannot enforce
# the sandbox's isolation fails at plan/apply time, before any node or object
# is created.

data "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.cluster_location

  lifecycle {
    postcondition {
      condition     = !coalesce(self.enable_autopilot, false)
      error_message = "agent-sandbox-gke targets GKE Standard. Autopilot manages node pools itself and is not covered by this module."
    }

    # NetworkPolicy enforcement. Dataplane V2 always enforces it and cannot be
    # turned off (https://cloud.google.com/kubernetes-engine/docs/how-to/network-policy).
    postcondition {
      condition = (
        self.datapath_provider == "ADVANCED_DATAPATH" ||
        (
          var.allow_calico_network_policy &&
          try(self.network_policy[0].enabled, false) &&
          try(self.network_policy[0].provider, "") == "CALICO"
        )
      )
      error_message = "The cluster must enforce NetworkPolicy: GKE Dataplane V2 (datapath_provider = ADVANCED_DATAPATH), or Calico with allow_calico_network_policy = true. Without it the sandbox deny-all is an object nobody enforces."
    }

    # A CiliumClusterwideNetworkPolicy can add an egress allow for the sandbox
    # pods that the agent service's start check (namespaced NetworkPolicies
    # only) cannot see.
    postcondition {
      condition     = !coalesce(try(self.enable_cilium_clusterwide_network_policy, false), false)
      error_message = "enable_cilium_clusterwide_network_policy is on. A cluster-wide Cilium policy can open egress for the sandbox namespace, which the agent service cannot detect. Turn it off on this cluster."
    }

    # The worker reaches GCS through Workload Identity, and the sandbox pool runs
    # the GKE metadata server (workload_metadata_config.mode = GKE_METADATA),
    # which needs the cluster's workload pool.
    postcondition {
      condition     = try(self.workload_identity_config[0].workload_pool, "") == "${var.project_id}.svc.id.goog"
      error_message = "Workload Identity Federation for GKE must be enabled with workload_pool = <project_id>.svc.id.goog."
    }

    # The GKE-managed Agent Sandbox add-on serves agents.x-k8s.io/v1alpha1
    # (https://agent-sandbox.sigs.k8s.io/docs/use-cases/anthropic-managed-agents/);
    # the Reducto chart needs the v1beta1 API of the OSS controller this module
    # installs, and two installs would fight over the same CRDs.
    postcondition {
      condition     = !coalesce(try(self.addons_config[0].agent_sandbox_config[0].enabled, false), false)
      error_message = "The GKE-managed Agent Sandbox add-on (addons_config.agent_sandbox_config) is enabled. It serves v1alpha1; this module installs the OSS controller (v1beta1). Disable the add-on first."
    }

    # admissionregistration.k8s.io/v1 ValidatingAdmissionPolicy is GA from 1.30.
    postcondition {
      condition = (
        tonumber(regex("^(\\d+)\\.(\\d+)", self.master_version)[0]) > 1 ||
        tonumber(regex("^(\\d+)\\.(\\d+)", self.master_version)[1]) >= 30
      )
      error_message = "The control plane must run Kubernetes 1.30 or later (ValidatingAdmissionPolicy v1)."
    }
  }
}

locals {
  workload_pool = "${var.project_id}.svc.id.goog"
}
