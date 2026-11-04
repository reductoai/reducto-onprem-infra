output "sandbox_namespace" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.namespace"
  value       = var.sandbox_namespace
}

output "runtime_class_name" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.runtimeClassName (provided by GKE Sandbox)."
  value       = var.runtime_class_name
}

output "sandbox_node_selector" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.nodeSelector. The pool's own label plus the GKE Sandbox label."
  value       = merge(local.sandbox_node_labels, local.gke_sandbox_label)
}

output "sandbox_tolerations" {
  description = "agentService.sandboxProviders.k8sAgentSandbox.tolerations. The pool's taint plus the GKE Sandbox taint (the gvisor RuntimeClass may add the latter too; a duplicate is harmless)."
  value = [
    merge(local.sandbox_node_taint, { operator = "Equal" }),
    merge(local.gke_sandbox_taint, { operator = "Equal" }),
  ]
}

output "k8s_agent_sandbox_values" {
  description = "The cluster-specific part of agentService.sandboxProviders.k8sAgentSandbox. Merge with enabled, warmPools, image, and auth in your values file."
  value = {
    namespace        = var.sandbox_namespace
    runtimeClassName = var.runtime_class_name
    allowRunc        = false
    nodeSelector     = merge(local.sandbox_node_labels, local.gke_sandbox_label)
    tolerations = [
      merge(local.sandbox_node_taint, { operator = "Equal" }),
      merge(local.gke_sandbox_taint, { operator = "Equal" }),
    ]
    networkPolicy = {
      enabled = true
      # Terraform owns the deny-all (namespace.tf).
      createDenyAll = false
    }
  }
}

output "worker_gsa_email" {
  description = "Google service account the Reducto worker KSA impersonates (null when enable_worker_workload_identity = false)."
  value       = one(google_service_account.worker[*].email)
}

output "worker_service_account_annotations" {
  description = "Chart serviceAccount.annotations for the worker KSA (Workload Identity)."
  value = var.enable_worker_workload_identity ? tomap({
    "iam.gke.io/gcp-service-account" = google_service_account.worker[0].email
  }) : tomap({})
}

output "sandbox_node_pool_name" {
  description = "Name of the GKE Sandbox node pool."
  value       = google_container_node_pool.sandbox.name
}

output "sandbox_node_service_account" {
  description = "Email of the sandbox nodes' Google service account."
  value       = google_service_account.sandbox_node.email
}

output "sandbox_pod_cidr" {
  description = "Pod range of the sandbox pool (the VPC firewall source range), or null."
  value       = var.sandbox_pod_range == null ? null : var.sandbox_pod_range.cidr
}

output "agent_sandbox_controller_version" {
  description = "Vendored kubernetes-sigs/agent-sandbox release."
  value       = "v1.0.7"
}
