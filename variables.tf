variable "region" {
  default = "us-east-1"
}

variable "cluster_name" {
  default = "reducto-ai"
}

variable "vpc_cidr" {
  default = "10.125.0.0/16"
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
  type    = bool
  default = true
}

variable "cluster_endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "db_instance_class" {
  type        = string
  description = "Instance class for Reducto Postgres database"
  default     = "db.t4g.medium"
}

variable "db_multi_az" {
  default = true
}

variable "db_deletion_protection" {
  default = true
}

variable "db_username" {
  default     = "reducto"
  description = "Postgres DB username"
}

variable "reducto_helm_repo_username" {
  description = "Username for Helm Registry for Reducto Helm Chart"
}

variable "reducto_helm_repo_password" {
  sensitive   = true
  description = "Password for Helm Registry for Reducto Helm Chart"
}

variable "reducto_helm_chart_version" {
  description = "Reducto Helm Chart version"
  default     = "1.9.55"
}

variable "reducto_helm_chart" {
  description = "Path to Helm Chart on OCI registry"
  default     = "oci://registry.reducto.ai/reducto-api/reducto"
}

variable "create_reducto_helm_release" {
  description = "Create Reducto Helm Release, useful if you manage k8s resources outside of terraform"
  type        = bool
  default     = true
}

variable "reducto_host" {
  description = "Full host DNS for Reducto (Example: reducto.mydomain.com)"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for Cert Manager to use DNS solver for issuing TLS certificates"
  sensitive   = true
}

# Configuration for monitoring and alerting

variable "slack_webhook_url" {
  description = "Slack Webhook URL for Alertmanager"
  sensitive   = true
}

variable "datadog_site" {
  description = "Datadog site"
  default     = "us3.datadoghq.com"
}

variable "datadog_api_key" {
  description = "Datadog API key"
  sensitive   = true
  default     = ""
}

# Configuration for vLLM

variable "enable_nvidia_device_plugin" {
  type        = bool
  default     = false
  description = "Whether to install the NVIDIA device plugin for GPU support"
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
