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
  description = "Provision a private, TLS-enabled Amazon ElastiCache for Valkey replication group and wire Reducto to it. Opt in when using the Redis-backed queue architecture or another Redis-backed feature."
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
