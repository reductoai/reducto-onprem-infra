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
  type = bool
  default = true
}

variable "cluster_endpoint_public_access_cidrs" {
  type = list(string)
  default = [ "0.0.0.0/0" ]
}

variable "db_instance_class" {
  type = string
  description = "Instance class for Reducto Postgres database"
  default = "db.t4g.medium"
}

variable "db_multi_az" {
  default = true
}

variable "db_deletion_protection" {
  default = true
}

variable "db_username" {
  default = "reducto"
  description = "Postgres DB username"
}

variable "reducto_helm_repo_username" {
  description = "Username for Helm Registry for Reducto Helm Chart"
}

variable "reducto_helm_repo_password" {
  sensitive = true
  description = "Password for Helm Registry for Reducto Helm Chart"
}

variable "reducto_helm_chart_version" {
  description = "Reducto Helm Chart version"
  default = "1.9.81"
}

variable "reducto_helm_chart" {
  description = "Path to Helm Chart on OCI registry"
  default = "oci://registry.reducto.ai/reducto-api/reducto"
}

variable "reducto_host" {
  description = "Full host DNS for Reducto (Example: reducto.mydomain.com)"
}

variable "openai_api_key" {
  sensitive = true
}

variable "reducto_nlb_cert_arn" {
  description = "ARN of the SSL certificate for the NLB"
  type        = string
}


