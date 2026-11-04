################################################################################
# Cluster
################################################################################

variable "project_id" {
  description = "GCP project of the GKE cluster (and of the Workload Identity pool <project>.svc.id.goog)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the existing GKE Standard cluster."
  type        = string
}

variable "cluster_location" {
  description = "Region or zone of the existing GKE cluster."
  type        = string
}

variable "allow_calico_network_policy" {
  description = "Accept a legacy-dataplane cluster with Calico network policy enforcement instead of GKE Dataplane V2. Dataplane V2 is the only enforcement path this module has been reasoned about for the pod-to-own-node path; set true only after the own-node probe in docs/install/gke-agent-sandbox.md fails closed on your cluster."
  type        = bool
  default     = false
}

################################################################################
# Sandbox node pool
################################################################################

variable "node_pool_name" {
  description = "Name of the dedicated GKE Sandbox (gVisor) node pool."
  type        = string
  default     = "reducto-sandbox"
}

variable "node_machine_type" {
  description = "Machine type of the sandbox nodes. gVisor needs a COS node image; shared-core types (e2-micro/small/medium) are not supported."
  type        = string
  default     = "n2-standard-8"
}

variable "node_disk_size_gb" {
  description = "Boot disk size of each sandbox node. Size for (pods per node x the chart's ephemeral-storage limit, default 10Gi) plus about 20Gi of images and logs."
  type        = number
  default     = 200
}

variable "node_disk_type" {
  description = "Boot disk type of the sandbox nodes."
  type        = string
  default     = "pd-balanced"
}

variable "node_locations" {
  description = "Zones of the sandbox node pool. Empty: the cluster's node locations."
  type        = list(string)
  default     = []
}

variable "node_min_count" {
  description = "Minimum sandbox nodes per zone (cluster autoscaler). Keep >= 1 so the warm pool has somewhere to run."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum sandbox nodes per zone (cluster autoscaler)."
  type        = number
  default     = 3
}

variable "max_pods_per_node" {
  description = "Max pods per sandbox node. Null: the cluster default. Must fit the pod range (each node takes a /24 for 110 pods)."
  type        = number
  default     = null
}

variable "node_service_account_extra_roles" {
  description = "Extra project roles for the sandbox node service account, e.g. [\"roles/artifactregistry.reader\"] when the -agent-sandbox image is in Artifact Registry in this project. The base grant is roles/container.defaultNodeServiceAccount only."
  type        = list(string)
  default     = []
}

variable "node_resource_labels" {
  description = "GCE resource labels on the sandbox node VMs."
  type        = map(string)
  default     = {}
}

variable "sandbox_pod_range" {
  description = <<-EOT
    Dedicated secondary range for the sandbox pool's pod IPs (multi-pod CIDR), so the VPC firewall can name sandbox pods by source range.
      name   - secondary range name on the cluster subnet.
      cidr   - its CIDR (the firewall source range). Must match the existing range when create = false.
      create - true: GKE creates the range on the subnet (needs permission to modify the subnet, so not a Shared VPC service project). false: use an existing range.
    Null disables the VPC firewall backstop; that is refused unless accept_no_vpc_firewall = true.
  EOT
  type = object({
    name   = string
    cidr   = string
    create = bool
  })
  default = null
}

variable "accept_no_vpc_firewall" {
  description = "Allow sandbox_pod_range = null (no VPC firewall backstop between sandbox pods and other VMs). NetworkPolicy remains the only control."
  type        = bool
  default     = false
}

variable "vpc_firewall_priority" {
  description = "Priority of the VPC deny rule. Must be lower (stronger) than every allow rule that admits the pod range, including the GKE-managed gke-<cluster>-*-all rule (1000)."
  type        = number
  default     = 100
}

variable "vpc_firewall_logging" {
  description = "Log matches of the VPC deny rule. A sandbox has no egress, so any match is an escape attempt worth seeing."
  type        = bool
  default     = true
}

################################################################################
# Kubernetes objects
################################################################################

variable "sandbox_namespace" {
  description = "Namespace of the sandbox pods (chart agentService.sandboxProviders.k8sAgentSandbox.namespace). Must not be the Reducto release namespace."
  type        = string
  default     = "reducto-agent-sandbox"

  validation {
    condition     = var.sandbox_namespace != "agent-sandbox-system"
    error_message = "sandbox_namespace must not be agent-sandbox-system (the controller namespace)."
  }
}

variable "runtime_class_name" {
  description = "RuntimeClass of the sandbox pods. GKE Sandbox provides `gvisor`; do not change unless you run another sandbox runtime."
  type        = string
  default     = "gvisor"
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

################################################################################
# Reducto worker Workload Identity (GCS staging)
################################################################################

variable "enable_worker_workload_identity" {
  description = "Create the worker GSA, its bucket and signBlob grants, and the Workload Identity binding for the worker KSA."
  type        = bool
  default     = true
}

variable "bucket_name" {
  description = "Existing GCS bucket the Reducto worker stages agent-service inputs and outputs in (signed URLs)."
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

variable "worker_gsa_account_id" {
  description = "account_id of the worker Google service account (6-30 chars)."
  type        = string
  default     = "reducto-worker"
}
