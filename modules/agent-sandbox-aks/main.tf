# AKS installation path for the on-prem agent-service sandbox prerequisites
# (reductoai/api agent-service/AGENTS.md, "On-prem"). Applied against an
# EXISTING AKS cluster; it creates no cluster, VNet, or storage account.
#
# What it installs (the chart installs none of these):
#   node-pool.tf         dedicated Pod Sandboxing (Kata) pool, tainted + labeled
#   runtime-class.tf     RuntimeClass on the AKS Kata handler with scheduling
#   controller.tf *      kubernetes-sigs/agent-sandbox v1.0.7 (--extensions) +
#                        CRDs, agent-sandbox-system (PSS restricted),
#                        controller Role, the controller pod-create VAP
#   namespace.tf *       sandbox namespace (PSS restricted) + deny-all with
#                        ZERO egress (no DNS)
#   admission.tf *       native ValidatingAdmissionPolicies: Kata runtime, no SA
#                        token, sandbox nodeSelector, no host namespaces;
#                        Unmanaged SandboxTemplates; no egress rule
#   installer-rbac.tf *  optional least-privilege RBAC for the helm installer
#   network-policy.tf    Cilium egressDeny on Cilium clusters (AKS-specific)
#   workload-identity.tf user-assigned identity + federated credentials for the
#                        Reducto worker KSA, Blob Data Contributor + Delegator
#
# Files marked * (and manifests/) are shared verbatim with
# modules/agent-sandbox-gke; they should move to a shared
# modules/agent-sandbox-k8s.
#
# Ownership split with the Helm chart (installed with
# agentService.sandboxProviders.k8sAgentSandbox.networkPolicy.createDenyAll:
# false): Terraform owns the namespace, its deny-all, and the cluster-scoped
# objects; the chart owns the ingress policy (8080/9090 from the agent-service
# pods only), the agent-service Role/RoleBinding, SandboxTemplate /
# SandboxWarmPool, and the token Secrets.

data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = var.cluster_resource_group_name
}

# The azurerm data source does not export securityProfile.workloadIdentity or
# networkDataplane, so read them from ARM directly. The cluster preconditions
# live here as postconditions: the data source is read during plan, so a failed
# check fails the plan before any object is created.
data "azapi_resource" "cluster" {
  type        = "Microsoft.ContainerService/managedClusters@2024-09-01"
  resource_id = data.azurerm_kubernetes_cluster.this.id

  response_export_values = {
    kubernetes_version        = "properties.currentKubernetesVersion"
    network_plugin            = "properties.networkProfile.networkPlugin"
    network_policy            = "properties.networkProfile.networkPolicy"
    network_dataplane         = "properties.networkProfile.networkDataplane"
    oidc_issuer_enabled       = "properties.oidcIssuerProfile.enabled"
    oidc_issuer_url           = "properties.oidcIssuerProfile.issuerURL"
    workload_identity_enabled = "properties.securityProfile.workloadIdentity.enabled"
  }

  lifecycle {
    # The sandbox boundary is a NetworkPolicy object; the provider only sees the
    # object, so an engine that does not enforce it (networkPolicy "none") would
    # leave the sandboxes with open egress while every check passes.
    postcondition {
      condition = contains(var.allowed_network_policies, coalesce(try(self.output.network_policy, null), "none"))
      error_message = format(
        "Cluster %s has networkProfile.networkPolicy=%q; the sandbox needs one of %s. Use Azure CNI powered by Cilium (--network-dataplane cilium), or opt in to calico via allowed_network_policies.",
        var.cluster_name, coalesce(try(self.output.network_policy, null), "none"), jsonencode(var.allowed_network_policies),
      )
    }

    # ValidatingAdmissionPolicy is GA (admissionregistration.k8s.io/v1) from 1.30.
    postcondition {
      condition     = tonumber(split(".", self.output.kubernetes_version)[1]) >= 30
      error_message = "The cluster runs Kubernetes ${self.output.kubernetes_version}; this module needs 1.30+ (ValidatingAdmissionPolicy v1)."
    }

    postcondition {
      condition     = !var.enable_worker_workload_identity || try(self.output.oidc_issuer_enabled, false) == true
      error_message = "enable_worker_workload_identity needs the cluster OIDC issuer: az aks update -g <rg> -n <cluster> --enable-oidc-issuer."
    }

    postcondition {
      condition     = !(var.enable_worker_workload_identity && var.require_workload_identity_webhook) || try(self.output.workload_identity_enabled, false) == true
      error_message = "The AKS workload-identity webhook is off: az aks update -g <rg> -n <cluster> --enable-workload-identity, or set require_workload_identity_webhook = false and use the chart's azureWorkloadIdentity explicit projection."
    }
  }
}

locals {
  network_policy = data.azapi_resource.cluster.output.network_policy
  is_cilium      = local.network_policy == "cilium"

  # pss_restricted_labels and controller_namespace are defined in the shared
  # controller.tf.

  # Same names as the GKE module, which the shared admission.tf reads.
  sandbox_node_labels = { (var.node_label_key) = var.node_label_value }
  sandbox_toleration = {
    key      = var.node_taint_key
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }
}
