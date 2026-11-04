output "k8s_agent_sandbox_values" {
  description = "Cluster-specific agentService.sandboxProviders.k8sAgentSandbox values."
  value       = module.agent_sandbox.k8s_agent_sandbox_values
}

output "worker_service_account_annotations" {
  description = "Chart serviceAccount.annotations (Workload Identity)."
  value       = module.agent_sandbox.worker_service_account_annotations
}

output "worker_pod_labels" {
  description = "Pod labels for http/worker/streaqWorkerDefaults podLabels (workload-identity webhook)."
  value       = module.agent_sandbox.worker_pod_labels
}

output "network_policy_engine" {
  description = "Network policy engine the module verified."
  value       = module.agent_sandbox.network_policy_engine
}
