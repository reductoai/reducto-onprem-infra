output "chart_values_yaml" {
  description = "Reducto chart values from the module, as YAML. Merge into the release values file."
  value       = yamlencode(module.agent_sandbox.chart_values)
}

output "runtime_class_name" {
  description = "RuntimeClass of the sandbox pods."
  value       = module.agent_sandbox.runtime_class_name
}

output "sandbox_namespace" {
  description = "Sandbox namespace."
  value       = module.agent_sandbox.sandbox_namespace
}

output "sandbox_node_pool_name" {
  description = "Pod Sandboxing node pool."
  value       = module.agent_sandbox.sandbox_node_pool_name
}

output "network_policy_engine" {
  description = "Network policy engine the module verified."
  value       = module.agent_sandbox.network_policy_engine
}

output "workload_identity_client_id" {
  description = "Client ID of the Reducto storage identity."
  value       = module.agent_sandbox.workload_identity_client_id
}
