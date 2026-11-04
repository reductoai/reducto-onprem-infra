# Output names follow modules/agent-sandbox-gke, so the chart-values wiring is
# the same on both clouds.

output "sandbox_namespace" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.namespace"
  value       = var.sandbox_namespace
}

output "runtime_class_name" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.runtimeClassName (Kata, AKS Pod Sandboxing)."
  value       = var.runtime_class_name
}

output "sandbox_node_selector" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.nodeSelector. The sandbox pool's label (the module's RuntimeClass adds it too; a duplicate is harmless)."
  value       = local.sandbox_node_labels
}

output "sandbox_tolerations" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.tolerations. The sandbox pool's taint (the module's RuntimeClass adds it too; a duplicate is harmless)."
  value       = [local.sandbox_toleration]
}

output "k8s_agent_sandbox_values" {
  description = "The cluster-specific part of agentService.sandboxProviders.k8sAgentSandbox. Merge with enabled, warmPools, image, resources, and auth in your values file."
  value = {
    namespace        = var.sandbox_namespace
    runtimeClassName = var.runtime_class_name
    allowRunc        = false
    nodeSelector     = local.sandbox_node_labels
    tolerations      = [local.sandbox_toleration]
    networkPolicy = {
      enabled = true
      # Terraform owns the deny-all (namespace.tf).
      createDenyAll = false
    }
  }
}

output "worker_service_account_annotations" {
  description = "Chart serviceAccount.annotations for the worker KSA (AKS workload-identity webhook)."
  value = var.enable_worker_workload_identity ? tomap({
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.reducto_storage[0].client_id
    "azure.workload.identity/tenant-id" = azurerm_user_assigned_identity.reducto_storage[0].tenant_id
  }) : tomap({})
}

output "worker_pod_labels" {
  description = "Pod label for http.podLabels, worker.podLabels and streaqWorkerDefaults.podLabels, so the webhook injects the identity (AKS only; GKE needs none)."
  value       = var.enable_worker_workload_identity ? tomap({ "azure.workload.identity/use" = "true" }) : tomap({})
}

output "worker_identity_client_id" {
  description = "Client ID of the Reducto storage identity (also the chart's azureWorkloadIdentity.clientId for explicit projection). Null when enable_worker_workload_identity = false."
  value       = one(azurerm_user_assigned_identity.reducto_storage[*].client_id)
}

output "worker_identity_tenant_id" {
  description = "Tenant ID of the Reducto storage identity (azureWorkloadIdentity.tenantId)."
  value       = one(azurerm_user_assigned_identity.reducto_storage[*].tenant_id)
}

output "oidc_issuer_url" {
  description = "OIDC issuer the federated credential trusts."
  value       = data.azapi_resource.cluster.output.oidc_issuer_url
}

output "sandbox_node_pool_name" {
  description = "Name of the Pod Sandboxing node pool."
  value       = azurerm_kubernetes_cluster_node_pool.sandbox.name
}

output "network_policy_engine" {
  description = "The cluster's network policy engine (networkProfile.networkPolicy), as checked by the module."
  value       = local.network_policy
}

output "agent_sandbox_controller_version" {
  description = "Vendored kubernetes-sigs/agent-sandbox release."
  value       = "v1.0.7"
}
