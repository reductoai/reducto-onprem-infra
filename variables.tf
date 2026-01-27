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
  default     = "1.11.32"
  type        = string
}

variable "reducto_helm_chart" {
  description = "Path to Helm Chart on OCI registry"
  default     = "oci://registry.reducto.ai/reducto-api/reducto"
  type        = string
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
