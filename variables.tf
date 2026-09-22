variable "region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster and prefix for related resources"
  type        = string
  default     = "reducto-ai"
}

variable "tags" {
  description = "Tags applied to AWS resources, including organization-required cost, environment, and ownership tags"
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.125.0.0/16"
}

variable "private_subnets" {
  description = "List of private subnets CIDRs"
  type        = list(string)
  default     = []
}

variable "public_subnets" {
  description = "List of public subnets CIDRs"
  type        = list(string)
  default     = []
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the EKS cluster API endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks allowed to access the public EKS API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_instance_class" {
  type        = string
  description = "Instance class for Reducto Postgres database"
  default     = "db.t4g.medium"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for RDS database for high availability"
  type        = bool
  default     = true
}

variable "db_deletion_protection" {
  description = "Enable deletion protection for RDS database to prevent accidental deletion"
  type        = bool
  default     = true
}

variable "db_username" {
  default     = "reducto"
  description = "Postgres DB username"
  type        = string
}

# Configuration for managed Redis-compatible queue/cache storage

variable "enable_elasticache" {
  description = "Provision a private, TLS-enabled Amazon ElastiCache for Valkey replication group and wire Reducto to it. Opt in when using the New Reducto Architecture or another Redis-backed feature."
  type        = bool
  default     = false
}

variable "elasticache_engine_version" {
  description = "Valkey engine version for the ElastiCache replication group"
  type        = string
  default     = "8.2"
}

variable "elasticache_node_type" {
  description = "Node type for the ElastiCache replication group"
  type        = string
  default     = "cache.t4g.small"
}

variable "elasticache_replica_count" {
  description = "Number of ElastiCache read replicas; set to at least one for automatic failover and Multi-AZ"
  type        = number
  default     = 1

  validation {
    condition     = var.elasticache_replica_count >= 0 && var.elasticache_replica_count <= 5 && floor(var.elasticache_replica_count) == var.elasticache_replica_count
    error_message = "elasticache_replica_count must be a whole number between 0 and 5."
  }
}

variable "elasticache_port" {
  description = "Port used by the ElastiCache replication group"
  type        = number
  default     = 6379

  validation {
    condition     = var.elasticache_port >= 1 && var.elasticache_port <= 65535
    error_message = "elasticache_port must be between 1 and 65535."
  }
}

variable "elasticache_snapshot_retention_limit" {
  description = "Number of days ElastiCache snapshots are retained; set to zero to disable automatic snapshots"
  type        = number
  default     = 7

  validation {
    condition     = var.elasticache_snapshot_retention_limit >= 0 && var.elasticache_snapshot_retention_limit <= 35
    error_message = "elasticache_snapshot_retention_limit must be between 0 and 35."
  }
}

variable "elasticache_apply_immediately" {
  description = "Apply ElastiCache changes immediately instead of waiting for the maintenance window"
  type        = bool
  default     = false
}

variable "enable_reducto" {
  type        = bool
  default     = true
  description = "Whether to deploy the Reducto application via Helm"
}

variable "reducto_helm_repo_username" {
  description = "Username for Helm Registry for Reducto Helm Chart"
  type        = string
}

variable "reducto_helm_repo_password" {
  sensitive   = true
  description = "Password for Helm Registry for Reducto Helm Chart"
  type        = string
}

variable "reducto_helm_chart_version" {
  description = "Reducto Helm Chart version"
  default     = "1.12.6"
  type        = string
}

variable "reducto_helm_chart" {
  description = "Path to Helm Chart on OCI registry"
  default     = "oci://registry.reducto.ai/reducto-api/reducto"
  type        = string
}

variable "reducto_extra_values_files" {
  description = "Paths to additional Helm values files layered last. Use this for deployment-specific queue worker settings."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for values_path in var.reducto_extra_values_files : can(file(values_path))])
    error_message = "Every reducto_extra_values_files entry must be a readable file path."
  }
}

variable "reducto_host" {
  description = "Full host DNS for Reducto (Example: reducto.mydomain.com)"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for Cert Manager to use DNS solver for issuing TLS certificates"
  sensitive   = true
  type        = string
}

# Configuration for monitoring and alerting

variable "slack_webhook_url" {
  description = "Slack Webhook URL for Alertmanager"
  sensitive   = true
  type        = string
}

variable "datadog_site" {
  description = "Datadog site"
  default     = "us3.datadoghq.com"
  type        = string
}

variable "datadog_api_key" {
  description = "Datadog API key"
  sensitive   = true
  default     = ""
  type        = string
}

# Configuration for vLLM

variable "enable_nvidia_device_plugin" {
  type        = bool
  default     = false
  description = "Whether to install the NVIDIA device plugin for GPU support"
}

variable "enable_gpu_managed_node_group" {
  type        = bool
  default     = false
  description = "Whether to create the GPU managed node group (system_gpu) for GPU workloads"
}

variable "enable_vllm_stack" {
  type        = bool
  default     = false
  description = "Whether to deploy the vLLM stack on the cluster"
}

variable "vllm_stack_hf_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Hugging Face API token used by the vLLM stack for model access"
}

# Configuration for OpenTelemetry Collector

variable "enable_otel_collector" {
  type        = bool
  default     = false
  description = "Whether to deploy the OpenTelemetry Collector on the cluster"
}

variable "otel_host" {
  type        = string
  default     = ""
  description = "FQDN for exposing the OpenTelemetry Collector"
}

variable "otel_auth_token" {
  description = "Auth token used by the OpenTelemetry collector"
  type        = string
  sensitive   = true
  default     = ""
}

variable "otel_datadog_api_key" {
  description = "Datadog API key used by the OpenTelemetry collector exporter"
  type        = string
  sensitive   = true
  default     = "admin"
}

# Helm Configuration

variable "helm_release_timeout" {
  description = "Timeout in seconds for Helm release operations"
  type        = number
  default     = 900 # 15 minutes
}

# Configuration for the Agent Sandbox substrate (gVisor-isolated sandbox pods,
# Kyverno enforcement, Envoy Gateway egress). See agent-sandbox.tf, gvisor.tf,
# kyverno.tf, pi-egress.tf. Off by default so it has zero effect on any other
# use of this repo.

variable "enable_agent_sandbox" {
  type        = bool
  default     = false
  description = "Whether to install the Agent Sandbox controller/CRDs, gVisor RuntimeClass + sandbox NodePool, and the Pi egress gateway substrate. Requires var.enable_kyverno = true (set it separately) for the require-sandbox-gvisor enforcement policy."

  validation {
    condition     = !var.enable_agent_sandbox || var.enable_kyverno
    error_message = "enable_agent_sandbox requires enable_kyverno = true (require-sandbox-gvisor is a Kyverno policy)."
  }

  # The sandbox NetworkPolicy blocks private ranges, so it only isolates the
  # *private* EKS endpoint. A public endpoint open to 0.0.0.0/0 is reachable
  # from a sandbox pod via the NAT gateway like any other public :443 host.
  validation {
    condition     = !var.enable_agent_sandbox || !var.cluster_endpoint_public_access || !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "enable_agent_sandbox requires cluster_endpoint_public_access = false, or cluster_endpoint_public_access_cidrs restricted to trusted CIDRs (not 0.0.0.0/0): sandbox pods can reach a world-open public API endpoint."
  }

  validation {
    condition     = !var.enable_agent_sandbox || var.sandbox_ami_id != ""
    error_message = "enable_agent_sandbox requires sandbox_ami_id: sandbox nodes boot from a hardened AMI with gVisor baked in; runsc is not installed at node boot."
  }
}

variable "sandbox_ami_id" {
  type        = string
  default     = ""
  description = "AMI ID for reducto-sandbox Karpenter nodes, built by the internal image pipeline with gVisor (runsc + containerd-shim-runsc-v1) baked in at sandbox_runsc_path. Must be an AL2023-based EKS image (nodeadm bootstrap) for the cluster's Kubernetes version. Required when enable_agent_sandbox = true."

  validation {
    condition     = var.sandbox_ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.sandbox_ami_id))
    error_message = "sandbox_ami_id must look like ami-0123456789abcdef0."
  }
}

variable "sandbox_node_provisioner" {
  type        = string
  default     = "karpenter"
  description = "How reducto-sandbox nodes are provisioned: \"karpenter\" (NodePool + EC2NodeClass in karpenter.tf) or \"managed_node_group\" (EKS managed node group in eks.tf, for clusters that do not run Karpenter). Both boot sandbox_ami_id with the same node-type label and reducto.ai/sandbox taint."

  validation {
    condition     = contains(["karpenter", "managed_node_group"], var.sandbox_node_provisioner)
    error_message = "sandbox_node_provisioner must be \"karpenter\" or \"managed_node_group\"."
  }
}

variable "sandbox_managed_node_group" {
  type = object({
    instance_types = optional(list(string), ["m7i.xlarge", "m7i.2xlarge"])
    min_size       = optional(number, 0)
    max_size       = optional(number, 10)
    desired_size   = optional(number, 1)
    disk_size_gb   = optional(number, 150)
  })
  default     = {}
  description = "Sizing for the reducto-sandbox EKS managed node group (only used when sandbox_node_provisioner = \"managed_node_group\"). On-demand only."
}

variable "sandbox_runsc_path" {
  type        = string
  default     = "/usr/local/bin/runsc"
  description = "Path of the runsc binary inside sandbox_ami_id (containerd-shim-runsc-v1 must be on containerd's PATH in the same image)."
}

variable "enable_kyverno" {
  type        = bool
  default     = false
  description = "Whether to install Kyverno and its cluster policies"
}

variable "kyverno_chart_version" {
  type        = string
  default     = "3.9.0"
  description = "Kyverno Helm chart version"
}

variable "kyverno_admission_replicas" {
  type        = number
  default     = 3
  description = "Replicas for the Kyverno admission controller. Its webhooks fail closed (failurePolicy: Fail), so it must be HA: Kyverno requires 1 or an odd number >= 3."

  validation {
    condition     = var.kyverno_admission_replicas == 1 || (var.kyverno_admission_replicas >= 3 && var.kyverno_admission_replicas % 2 == 1)
    error_message = "kyverno_admission_replicas must be 1 or an odd number >= 3."
  }
}

variable "agent_sandbox_write_namespaces" {
  type        = list(string)
  default     = ["agent-sandbox-system", "reducto-pi-sandbox"]
  description = "Namespaces the agent-sandbox controller is allowed to create/update pods, PVCs, services, and network policies in. Must include agent-sandbox-system."

  validation {
    condition     = contains(var.agent_sandbox_write_namespaces, "agent-sandbox-system")
    error_message = "agent_sandbox_write_namespaces must include \"agent-sandbox-system\"."
  }
}

variable "pi_sandbox_namespace" {
  type        = string
  default     = "reducto-pi-sandbox"
  description = "Namespace where sandbox runtime pods (SandboxClaims) are created"
}

variable "pi_sandbox_client_namespace" {
  type        = string
  default     = "reducto-pi-sandbox-client"
  description = "Namespace whose workloads are allowed to reach the sandbox runtime port; created if it doesn't already exist"
}

variable "pi_egress_namespace" {
  type        = string
  default     = "reducto-pi-egress"
  description = "Namespace containing the Envoy data plane and edge Gateway/routes for the Pi egress stack"
}

variable "pi_egress_controller_namespace" {
  type        = string
  default     = "reducto-pi-egress-system"
  description = "Namespace containing the Envoy Gateway control plane for the Pi egress stack"
}

variable "sandbox_allow_public_egress" {
  type        = bool
  default     = false
  description = "Allow sandbox pods to reach the public internet (public DNS + HTTPS, private ranges excluded) and the Envoy egress proxy. Default false: sandbox egress is deny-all except kube-dns and sandbox_egress_allow, so untrusted agent code has no route to exfiltrate data (e.g. model weights). Any allowed public destination, even behind a host allowlist, is an exfiltration channel; enable only if you accept that."
}

variable "sandbox_egress_allow" {
  type = list(object({
    namespace = string
    port      = number
    protocol  = optional(string, "TCP")
  }))
  default     = []
  description = "In-cluster destinations sandbox pods may reach, as namespace + port (e.g. [{ namespace = \"reducto\", port = 80 }] for the Reducto API). Namespace-scoped by design: cannot name VPC or public addresses."

  validation {
    condition     = alltrue([for a in var.sandbox_egress_allow : contains(["TCP", "UDP", "SCTP"], a.protocol) && a.port >= 1 && a.port <= 65535])
    error_message = "sandbox_egress_allow entries need protocol TCP/UDP/SCTP and port 1-65535."
  }
}

variable "sandbox_blocked_egress_cidrs" {
  type        = list(string)
  default     = []
  description = "Only used when sandbox_allow_public_egress = true. Extra CIDRs sandbox pods must never reach, on top of RFC1918, 100.64.0.0/10 (CGNAT, used by EKS custom networking pod CIDRs), 169.254.0.0/16 (link-local/IMDS), var.vpc_cidr, the subnet CIDRs, and the cluster service CIDR. Add secondary VPC CIDRs, peered VPCs, or on-prem ranges here."

  validation {
    condition     = alltrue([for c in var.sandbox_blocked_egress_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":")])
    error_message = "sandbox_blocked_egress_cidrs must be valid IPv4 CIDRs (the sandbox NetworkPolicy is IPv4-only; IPv6 egress is denied entirely)."
  }
}

variable "envoy_gateway_chart_version" {
  type        = string
  default     = "v1.8.1"
  description = "Envoy Gateway Helm chart version (gateway-helm, oci://docker.io/envoyproxy)"
}
