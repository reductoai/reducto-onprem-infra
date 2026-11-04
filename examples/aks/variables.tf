variable "subscription_id" {
  description = "Azure subscription of the AKS cluster."
  type        = string
}

variable "cluster_name" {
  description = "Existing AKS cluster name."
  type        = string
}

variable "cluster_resource_group_name" {
  description = "Resource group of the AKS cluster."
  type        = string
}

variable "node_vm_size" {
  description = "Sandbox node VM size (generation 2, nested virtualization, x86-64)."
  type        = string
  default     = "Standard_D16s_v5"
}

variable "node_min_count" {
  description = "Minimum sandbox node count."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum sandbox node count."
  type        = number
  default     = 3
}

variable "node_vnet_subnet_id" {
  description = "Sandbox node subnet. Null: the cluster default."
  type        = string
  default     = null
}

variable "node_zones" {
  description = "Availability zones of the sandbox pool."
  type        = list(string)
  default     = []
}

variable "sandbox_namespace" {
  description = "Sandbox namespace."
  type        = string
  default     = "reducto-agent-sandbox"
}

variable "reducto_namespace" {
  description = "Namespace of the Reducto Helm release."
  type        = string
  default     = "reducto"
}

variable "worker_service_account_name" {
  description = "Reducto worker KSA: <release>-reducto."
  type        = string
  default     = "reducto-reducto"
}

variable "storage_account_id" {
  description = "ARM ID of the customer storage account."
  type        = string
}

variable "storage_container_names" {
  description = "Blob containers the Reducto worker reads, writes, and deletes in."
  type        = list(string)
}

variable "tags" {
  description = "Tags for the Azure resources."
  type        = map(string)
  default     = {}
}
