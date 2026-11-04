################################################################################
# Cluster
################################################################################

variable "cluster_name" {
  description = "Name of the existing AKS cluster the sandbox prerequisites are installed into."
  type        = string
}

variable "cluster_resource_group_name" {
  description = "Resource group of the existing AKS cluster."
  type        = string
}

variable "allowed_network_policies" {
  description = <<-EOT
    AKS network policy engines (networkProfile.networkPolicy) the module accepts. The sandbox
    boundary is a NetworkPolicy, so a cluster without an enforcing engine fails the plan.
    "cilium" (Azure CNI powered by Cilium) is the qualified path: it enforces pod -> own-node
    egress and gets the extra CiliumClusterwideNetworkPolicy deny. "calico" is accepted on
    opt-in only (see docs/install/aks-agent-sandbox.md). "azure" (Azure NPM) is not accepted:
    Linux NPM retires on 2028-09-30 and its pod -> own-node behaviour is unverified.
  EOT
  type        = list(string)
  default     = ["cilium"]

  validation {
    condition     = length(var.allowed_network_policies) > 0 && alltrue([for p in var.allowed_network_policies : contains(["cilium", "calico"], p)])
    error_message = "allowed_network_policies may contain only \"cilium\" and \"calico\"."
  }
}

variable "tags" {
  description = "Tags applied to the Azure resources this module creates."
  type        = map(string)
  default     = {}
}

################################################################################
# Sandbox node pool (AKS Pod Sandboxing / Kata)
################################################################################

variable "node_pool_name" {
  description = "Name of the dedicated Pod Sandboxing node pool (Linux pool names: 1-12 lowercase alphanumerics, starting with a letter)."
  type        = string
  default     = "sandbox"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,11}$", var.node_pool_name))
    error_message = "node_pool_name must be 1-12 lowercase alphanumerics and start with a letter."
  }
}

variable "node_vm_size" {
  description = <<-EOT
    VM size of the sandbox nodes. Pod Sandboxing needs a generation 2 x86-64 size that supports
    nested virtualization (for example Dsv3/Dsv5/Dsv6). Arm64 sizes are not supported. Each Kata
    pod VM takes its full memory limit (plus RuntimeClass overhead) from the node, so size by
    limits, not requests.
  EOT
  type        = string
  default     = "Standard_D16s_v5"
}

variable "node_min_count" {
  description = "Minimum node count of the sandbox pool (cluster autoscaler)."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum node count of the sandbox pool (cluster autoscaler)."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_count >= 1
    error_message = "node_max_count must be at least 1."
  }
}

variable "node_max_pods" {
  description = "Max pods per sandbox node. Null keeps the AKS default for the cluster's network plugin."
  type        = number
  default     = null
}

variable "node_os_disk_size_gb" {
  description = "OS disk size of the sandbox nodes. The sandbox emptyDirs (ephemeral-storage) live on it."
  type        = number
  default     = 256
}

variable "node_zones" {
  description = "Availability zones of the sandbox pool. Empty: no zone pinning."
  type        = list(string)
  default     = []
}

variable "node_vnet_subnet_id" {
  description = "Subnet of the sandbox nodes. Null: the cluster default. Must match the cluster's IPAM mode."
  type        = string
  default     = null
}

variable "node_pod_subnet_id" {
  description = "Pod subnet of the sandbox pool (Azure CNI pod subnet mode only). Null for overlay."
  type        = string
  default     = null
}

variable "node_orchestrator_version" {
  description = "Kubernetes version of the sandbox pool. Null: the control-plane version at creation."
  type        = string
  default     = null
}

variable "node_upgrade_max_surge" {
  description = "upgrade_settings.max_surge of the sandbox pool. A surge node lets the warm pool refill before an old node drains."
  type        = string
  default     = "1"
}

variable "node_upgrade_drain_timeout_minutes" {
  description = "upgrade_settings.drain_timeout_in_minutes. An AKS upgrade evicts claimed sandboxes; keep it above the longest session you are willing to wait for."
  type        = number
  default     = 60
}

variable "node_label_key" {
  description = "Node label key of the sandbox pool. Same key/value as the hosted reducto-sandbox NodePool."
  type        = string
  default     = "node-type"
}

variable "node_label_value" {
  description = "Node label value of the sandbox pool."
  type        = string
  default     = "reducto-sandbox"
}

variable "node_taint_key" {
  description = "NoSchedule taint key of the sandbox pool. Same as hosted (reducto.ai/sandbox=true:NoSchedule)."
  type        = string
  default     = "reducto.ai/sandbox"
}

################################################################################
# RuntimeClass
################################################################################

variable "create_runtime_class" {
  description = <<-EOT
    true: create runtime_class_name on the AKS Kata handler with the sandbox pool's nodeSelector +
    toleration and an explicit overhead (the hosted gvisor pattern). false: use a RuntimeClass that
    already exists, normally the AKS built-in kata-vm-isolation (set runtime_class_name to it); the
    pods then select the pool through the k8s_agent_sandbox_values nodeSelector/tolerations.
  EOT
  type        = bool
  default     = true
}

variable "runtime_class_name" {
  description = "RuntimeClass the sandbox pods must use (chart runtimeClassName; the admission policy pins it). Created by the module when create_runtime_class = true; otherwise it must exist (AKS built-in: kata-vm-isolation). Must not be \"gvisor\" (the chart reserves it for hosted)."
  type        = string
  default     = "reducto-kata"

  validation {
    condition     = var.runtime_class_name != "gvisor" && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.runtime_class_name))
    error_message = "runtime_class_name must be a DNS label and must not be \"gvisor\"."
  }
}

variable "runtime_class_handler" {
  description = "containerd handler of the AKS Kata runtime. Microsoft documents \"kata\"; confirm with `kubectl get runtimeclass kata-vm-isolation -o jsonpath='{.handler}'`."
  type        = string
  default     = "kata"
}

variable "runtime_class_overhead" {
  description = <<-EOT
    RuntimeClass podFixed overhead (host-side Kata shim, Cloud Hypervisor, virtiofsd). Microsoft's
    reference table gives 256Mi of overhead for a 2Gi pod VM, the chart's default memory limit.
    Raise memory with the sandbox memory limit.
  EOT
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "250m"
    memory = "256Mi"
  }
}

################################################################################
# agent-sandbox controller + namespaces
################################################################################

variable "sandbox_namespace" {
  description = "Namespace of the sandbox pods (agentService.sandboxProviders.k8sAgentSandbox.namespace). Must not be the Reducto release namespace."
  type        = string
  default     = "reducto-agent-sandbox"

  validation {
    condition     = var.sandbox_namespace != "agent-sandbox-system" && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.sandbox_namespace))
    error_message = "sandbox_namespace must be a DNS label and must not be agent-sandbox-system."
  }
}

variable "pss_version" {
  description = "Pod Security Standards version pinned on the controller and sandbox namespaces."
  type        = string
  default     = "latest"
}

variable "installer_subjects" {
  description = "RBAC subjects (the identity that runs `helm install`) granted the sandbox-namespace rights the chart needs: Role/RoleBinding/Secret/NetworkPolicy/SandboxTemplate/SandboxWarmPool write, the verbs the chart's agent-service Role grants, and get on RuntimeClasses. Empty: none (the installer is cluster-admin). Rights in the release namespace are not covered here."
  type = list(object({
    kind      = string
    name      = string
    namespace = optional(string)
  }))
  default = []
}

variable "create_cilium_egress_deny" {
  description = "On a Cilium cluster, also apply a CiliumClusterwideNetworkPolicy egressDeny for the sandbox namespace. Deny rules win over any allow, so a NetworkPolicy or CiliumNetworkPolicy added later cannot reopen egress. Ignored on Calico."
  type        = bool
  default     = true
}

################################################################################
# Workload Identity for the Reducto worker (Blob storage)
################################################################################

variable "enable_worker_workload_identity" {
  description = "Create the user-assigned identity, its federated credential, and the Blob role assignments for the Reducto worker KSA."
  type        = bool
  default     = true
}

variable "require_workload_identity_webhook" {
  description = "Fail the plan unless the cluster has the AKS workload-identity webhook enabled. Set false when the chart's explicit projection (azureWorkloadIdentity.enabled) is used instead; the OIDC issuer is required either way."
  type        = bool
  default     = true
}

variable "identity_name" {
  description = "Name of the user-assigned managed identity. Null: <cluster_name>-reducto-storage."
  type        = string
  default     = null
}

variable "identity_resource_group_name" {
  description = "Resource group of the managed identity. Null: the cluster resource group."
  type        = string
  default     = null
}

variable "reducto_namespace" {
  description = "Namespace of the Reducto Helm release."
  type        = string
  default     = "reducto"
}

variable "worker_service_account_name" {
  description = "KSA of the Reducto workers. The chart names it <release>-reducto (serviceAccount.create = true)."
  type        = string
  default     = "reducto-reducto"
}

variable "workload_identity_audience" {
  description = "Audience of the federated credentials. Must match the token audience the pods present (chart azureWorkloadIdentity.audience)."
  type        = string
  default     = "api://AzureADTokenExchange"
}

variable "storage_account_id" {
  description = "ARM ID of the customer storage account Reducto uses. Storage Blob Delegator is granted here (user delegation keys are an account-level operation). Required when enable_worker_workload_identity."
  type        = string
  default     = null
}

variable "storage_container_names" {
  description = "Blob containers in storage_account_id that get Storage Blob Data Contributor (read, write, delete; bounds the permissions of a user delegation SAS). Required when enable_worker_workload_identity."
  type        = list(string)
  default     = []
}
