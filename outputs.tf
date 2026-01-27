# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

# EKS Cluster Outputs
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS"
  value       = module.eks.oidc_provider_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "configure_kubectl" {
  description = "Command to configure kubectl for the EKS cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# RDS Database Outputs
output "db_instance_endpoint" {
  description = "Connection endpoint for the RDS instance"
  value       = module.rds.db_instance_endpoint
}

output "db_instance_name" {
  description = "Name of the RDS database"
  value       = module.rds.db_instance_identifier
}

output "db_proxy_endpoint" {
  description = "Connection endpoint for the RDS Proxy"
  value       = module.rds_proxy.proxy_endpoint
}

output "db_proxy_arn" {
  description = "ARN of the RDS Proxy"
  value       = module.rds_proxy.proxy_arn
}

# S3 Storage Outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket for Reducto storage"
  value       = aws_s3_bucket.reducto_storage.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket for Reducto storage"
  value       = aws_s3_bucket.reducto_storage.arn
}

# Reducto Application Outputs
output "reducto_host" {
  description = "Hostname where Reducto is accessible"
  value       = var.reducto_host
}

output "reducto_iam_role_arn" {
  description = "ARN of the IAM role for Reducto service account"
  value       = aws_iam_role.reducto.arn
}

# Region Output
output "region" {
  description = "AWS region where resources are deployed"
  value       = var.region
}
