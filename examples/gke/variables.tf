variable "project_id" {
  description = "GCP project of the cluster."
  type        = string
}

variable "cluster_name" {
  description = "Existing GKE Standard cluster."
  type        = string
}

variable "cluster_location" {
  description = "Region or zone of the cluster."
  type        = string
}

variable "node_machine_type" {
  description = "Sandbox node machine type."
  type        = string
  default     = "n2-standard-8"
}

variable "node_min_count" {
  description = "Minimum sandbox nodes per zone."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum sandbox nodes per zone."
  type        = number
  default     = 3
}

variable "sandbox_pod_range" {
  description = "Dedicated pod secondary range of the sandbox pool (see the module variable)."
  type = object({
    name   = string
    cidr   = string
    create = bool
  })
}

variable "node_service_account_extra_roles" {
  description = "Extra project roles for the sandbox node SA (e.g. roles/artifactregistry.reader)."
  type        = list(string)
  default     = []
}

variable "bucket_name" {
  description = "Existing GCS bucket of the Reducto worker."
  type        = string
}

variable "reducto_namespace" {
  description = "Namespace of the Reducto Helm release."
  type        = string
  default     = "reducto"
}

variable "worker_service_account_name" {
  description = "Worker KSA (<release>-reducto)."
  type        = string
  default     = "reducto-reducto"
}
