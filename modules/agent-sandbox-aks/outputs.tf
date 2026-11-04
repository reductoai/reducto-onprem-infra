output "sandbox_namespace" {
  description = "Namespace of the sandbox pods (agentService.sandboxProviders.k8sAgentSandbox.namespace)."
  value       = var.sandbox_namespace
}

output "runtime_class_name" {
  description = "RuntimeClass the sandbox pods use (agentService.sandboxProviders.k8sAgentSandbox.runtimeClassName)."
  value       = local.runtime_class_name
}

output "sandbox_node_pool_name" {
  description = "Name of the Pod Sandboxing node pool."
  value       = azurerm_kubernetes_cluster_node_pool.sandbox.name
}

output "sandbox_node_selector" {
  description = "Node label of the sandbox pool."
  value       = local.sandbox_node_selector
}

output "sandbox_toleration" {
  description = "Toleration for the sandbox pool taint."
  value       = local.sandbox_toleration
}

output "network_policy_engine" {
  description = "The cluster's network policy engine (networkProfile.networkPolicy), as checked by the module."
  value       = local.network_policy
}

output "workload_identity_client_id" {
  description = "Client ID of the Reducto storage identity (azure.workload.identity/client-id / azureWorkloadIdentity.clientId). Null when enable_workload_identity = false."
  value       = var.enable_workload_identity ? azurerm_user_assigned_identity.reducto_storage[0].client_id : null
}

output "workload_identity_tenant_id" {
  description = "Tenant ID of the Reducto storage identity."
  value       = var.enable_workload_identity ? azurerm_user_assigned_identity.reducto_storage[0].tenant_id : null
}

output "oidc_issuer_url" {
  description = "OIDC issuer the federated credentials trust."
  value       = data.azapi_resource.cluster.output.oidc_issuer_url
}

# The Reducto chart values that depend on this module. Merge into the release
# values; the rest of agentService (enabled, providerKeys, warmPools, profiles,
# image, providerRegion) is per install. Keys match reductoai/api
# helm-charts/reducto/values.yaml.
output "chart_values" {
  description = "Reducto Helm values produced by this module (merge into the release values; see docs/install/aks-agent-sandbox.md)."
  value = {
    for key, value in {
      agentService = {
        sandboxProviders = {
          k8sAgentSandbox = {
            for key, value in {
              enabled          = true
              namespace        = var.sandbox_namespace
              runtimeClassName = local.runtime_class_name
              allowRunc        = false
              # Terraform owns the deny-all (network-policy.tf).
              networkPolicy = {
                enabled       = true
                createDenyAll = false
              }
              # With the module's RuntimeClass, scheduling comes from the class.
              # With the AKS built-in class, the pods must select the pool.
              nodeSelector = local.sandbox_node_selector
              tolerations  = [local.sandbox_toleration]
            } : key => value if !(var.create_runtime_class && contains(["nodeSelector", "tolerations"], key))
          }
        }
      }
      # AKS workload-identity webhook path (api docs/onprem/azure_blob_storage.mdx).
      # Also add the pod label azure.workload.identity/use: "true" to http,
      # worker and streaqWorkerDefaults podLabels (see the install doc).
      serviceAccount = {
        create = true
        annotations = {
          "azure.workload.identity/client-id" = one(azurerm_user_assigned_identity.reducto_storage[*].client_id)
          "azure.workload.identity/tenant-id" = one(azurerm_user_assigned_identity.reducto_storage[*].tenant_id)
        }
      }
    } : key => value if key != "serviceAccount" || var.enable_workload_identity
  }
}
