output "k8s_agent_sandbox_values" {
  description = "Cluster-specific agentService.sandboxProviders.k8sAgentSandbox values."
  value       = module.agent_sandbox.k8s_agent_sandbox_values
}

output "worker_service_account_annotations" {
  description = "Chart serviceAccount.annotations (Workload Identity)."
  value       = module.agent_sandbox.worker_service_account_annotations
}
