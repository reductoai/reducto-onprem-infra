# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Terraform infrastructure-as-code for deploying Reducto (a document processing service) on AWS EKS (Elastic Kubernetes Service). The infrastructure creates a production-ready Kubernetes cluster with all necessary dependencies including database, storage, autoscaling, monitoring, and ingress.

## Architecture

### Core Components

The infrastructure is organized into several key modules:

1. **EKS Cluster** (`eks.tf`, `main.tf`): Kubernetes 1.34 cluster with managed node groups:
   - `system`: Tainted nodes for critical add-ons (m5.large, 2-10 nodes)
   - `system_gpu`: Optional GPU nodes (p5.48xlarge, enabled via `enable_gpu_managed_node_group = true`)

2. **VPC and Networking** (`vpc.tf`): Multi-AZ setup with:
   - Private subnets (/18) for workloads
   - Public subnets (/20) for load balancers
   - One NAT Gateway per availability zone
   - Subnets are tagged for EKS load balancer discovery and Karpenter

3. **Database** (`reducto-db.tf`):
   - PostgreSQL 16.6 on RDS with RDS Proxy for connection pooling
   - Credentials stored in AWS Secrets Manager
   - Database URL passed to Helm chart as environment variable

4. **Storage** (`reducto-bucket.tf`):
   - S3 bucket with 24-hour lifecycle policy
   - Deletion protection enabled via `lifecycle.prevent_destroy = true`

5. **Autoscaling** (`karpenter.tf`):
   - Karpenter for cluster node autoscaling
   - Default NodePool configured for compute-optimized instances (c5/c6 families)
   - Uses Bottlerocket OS on Karpenter-provisioned nodes

6. **Application Deployment** (`reducto-helm-release.tf`):
   - Reducto deployed via Helm from private OCI registry
   - IAM roles for service accounts (IRSA) for AWS resource access
   - Enabled by default (controlled via `enable_reducto` variable, default: true)

7. **Ingress** (`ingress-nginx-controller.tf`, `aws-load-balancer-controller.tf`):
   - Nginx Ingress Controller with NLB in private subnets
   - AWS Load Balancer Controller for managing AWS load balancers
   - TLS certificates via cert-manager with Cloudflare DNS01 challenge

8. **Monitoring** (`monitoring.tf`, `manifests/prometheus/`):
   - Prometheus stack with Alertmanager
   - Custom PrometheusRules for Reducto queue and 5xx metrics
   - Slack alerting integration

### Optional Components

- **vLLM Stack** (`vllm-stack.tf`): For GPU-based LLM inference (requires `enable_vllm_stack = true`)
- **NVIDIA Device Plugin** (`nvidia-device-plugin.tf`): Required for GPU support
- **OpenTelemetry Collector** (`opentelemetry-collector.tf`): Observability data collection
- **Datadog** (`datadog.tf`): Optional Datadog integration for metrics
- **Telegraf** (`telegraf.tf`): Metrics collection for Reducto

## Terraform Workflow

### Initial Setup

1. Configure `backend.tf` for remote state (or use local state for testing)
2. Review `variables.tf` and create `terraform.tfvars`:
   ```hcl
   reducto_helm_repo_username = "..."
   reducto_helm_repo_password = "..."
   reducto_host = "reducto.example.com"
   cloudflare_api_token = "..."
   slack_webhook_url = "..."
   ```

3. Run standard Terraform commands:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

### Common Operations

**Update kubeconfig:**
```bash
aws eks update-kubeconfig --region us-east-1 --name reducto-ai
```

**Port-forward to Reducto service:**
```bash
kubectl port-forward service/reducto-reducto-http 4567:80 -n reducto
```

**Check Karpenter logs:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter
```

**View Prometheus rules:**
```bash
kubectl get prometheusrules -n monitoring
```

### Teardown

To destroy infrastructure:

1. Comment out `lifecycle.prevent_destroy` block in `reducto-bucket.tf`
2. Set `db_deletion_protection = false` and run `terraform apply`
3. Run `terraform destroy`
4. Manually delete resources created outside Terraform:
   - NLB created by ingress-nginx
   - Karpenter-provisioned nodes
   - Empty the S3 bucket

## Important Patterns

### IAM Roles for Service Accounts (IRSA)

The Reducto application uses IRSA for S3 access. The pattern is:
1. Create IAM role with assume role policy for EKS OIDC provider (`reducto-iam.tf`)
2. Attach policies for required AWS services (S3, etc.)
3. Annotate Kubernetes ServiceAccount with IAM role ARN in Helm values

### Helm Values Organization

Helm values are split between:
- Static YAML files in `values/` directory
- Dynamic values inline in Terraform (for computed values like database URL, IAM roles)

### EKS Add-ons

EKS add-ons are managed via the `cluster_addons` block in `eks.tf`. All add-ons have explicit versions pinned and resource limits configured. The `aws-ebs-csi-driver` requires IRSA.

### Security Groups

Custom security group rules allow:
- VPC access to EKS control plane (port 443)
- Webhook admission traffic between cluster and nodes (port 8443)
- All traffic between nodes (for pod networking)

## Upgrades

See `MIGRATION_GUIDE.md` for version-specific upgrade instructions. When upgrading Kubernetes versions:
1. Update `cluster_version` in `eks.tf`
2. Update all add-on versions to compatible versions
3. EKS will perform rolling upgrade automatically
4. If node updates get stuck, may need to manually delete pods with restrictive PodDisruptionBudgets

## Variables and Configuration

Key variables to customize:
- `cluster_name`: EKS cluster name (default: "reducto-ai")
- `vpc_cidr`: VPC CIDR block (default: "10.125.0.0/16")
- `cluster_endpoint_public_access`: Enable public API endpoint (default: true)
- `cluster_endpoint_public_access_cidrs`: Restrict public access (default: ["0.0.0.0/0"])
- `db_instance_class`: RDS instance type (default: "db.t4g.medium")
- `reducto_helm_chart_version`: Reducto version to deploy

For GPU workloads, enable:
- `enable_gpu_managed_node_group = true` (creates the system_gpu managed node group)
- `enable_nvidia_device_plugin = true`
- `enable_vllm_stack = true` (and provide `vllm_stack_hf_token`)

## Notes

- All workloads run in private subnets for security
- The Reducto Helm release is enabled by default (set `enable_reducto = false` to disable)
- Cloudflare DNS is used for TLS certificate issuance via cert-manager
- Database uses connection pooling via RDS Proxy
- S3 bucket has 24-hour expiration policy for all objects
- New AWS accounts require creating service-linked role for Spot instances: `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`
