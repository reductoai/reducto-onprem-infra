# Reducto

Install Reducto on EKS using Terraform.

![Reducto on-prem Architecture](./reducto-architecture-large.png)

## Overview

The project creates [Helm Release](./reducto-helm-release.tf) for Reducto on EKS in `reducto` namespace. And creates following required dependencies:
1. [RDS instance](./reducto-db.tf)
2. [S3 bucket](./reducto-bucket.tf)
3. [ElastiCache for Valkey](./reducto-cache.tf) for Redis-compatible queue and cache storage
4. [Keda](./keda.tf) (for autoscaling of Reducto workers in-cluster)
5. Auto scaling of cluster nodes ([Karpenter](./karpenter.tf) is configured, however you can use any cluster autoscaling tool)
6. [AWS Load balancer controller](./aws-load-balancer-controller.tf) or [Ingress Nginx](./ingress-nginx-controller.tf) (however you can use any ingress controller)

This project demonstrates fully working cluster that's needed to run Reducto.
Cloudflare is not a requirement, however its used here to setup TLS along with cert-manager.

Set `enable_elasticache = true` to provision a private, TLS-enabled,
AUTH-protected, Multi-AZ ElastiCache replication group running Valkey. The
stack passes its sensitive `rediss://` URL to the chart as both `REDIS_URL` and
`ELASTICACHE_URL` and disables the chart's single-pod Redis deployment. Protect
the Terraform state because it contains the generated AUTH token. Chart
`1.12.6` keeps the optional queue workers disabled by default (`streaqWorkerDefaults.enabled` is
`false` and `streaqWorkers` is empty), so ElastiCache also remains opt-in until
the New Reducto Architecture is enabled. Chart `1.12.6` supports managed
Redis TLS through the system trust store; no chart-specific CA mount is needed
for ElastiCache's publicly rooted certificate.
Use the `tags` input for account-required cost, environment, and ownership
tags; these tags are also propagated to nodes launched dynamically by
Karpenter and to the EKS managed node group's instances, network interfaces,
and volumes.

## New Reducto Architecture bridge (chart 1.12.6)

For the v1.12.6 → v1.13 migration, pin the chart, opt into managed Redis, and
layer the queue worker topology through `reducto_extra_values_files`. Keep the
legacy worker enabled during the bridge and start every rollout ratio at `0`;
follow the migration runbook for the full drain and ramp procedure.

```hcl
reducto_helm_chart_version = "1.12.6"
enable_elasticache         = true
reducto_extra_values_files = ["redis-queue-bridge.yaml"]
```

The CPU worker reserves 14 CPU and 26Gi; size the customer node pool to fit
that reservation before enabling the bridge.

`redis-queue-bridge.yaml`:

```yaml
env:
  WORKER_PROVIDER: STREAQ_LOCAL
  PARSE_STREAQ_TRAINABLE_ROLLOUT_RATIO: "0"
  PARSE_STREAQ_NON_TRAINABLE_ROLLOUT_RATIO: "0"
  STREAQ_CPU_WORKER_ROLLOUT_PCT: "0"
  STREAQ_CPU_COMPLETION_TRAINABLE_ROLLOUT_PCT: "0"
  STREAQ_CPU_COMPLETION_NON_TRAINABLE_ROLLOUT_PCT: "0"
streaqWorkers:
  io:
    enabled: true
    workerName: io
  cpu:
    enabled: true
    workerName: cpu
    useFullImage: true
    workerCount: 1
    replicaCount: 1
    kedaScaler: false
    resources:
      requests:
        cpu: 14
        memory: 26Gi
      limits:
        memory: 26Gi
worker:
  enabled: true
```

## Upgrades

For upgrade instructions and release notes, see [MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md).

## Terraform Documentation

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 6.28.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | 3.1.1 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | 1.19.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | 3.0.1 |
| <a name="requirement_null"></a> [null](#requirement\_null) | 3.2.4 |
| <a name="requirement_random"></a> [random](#requirement\_random) | 3.8.0 |

### Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.28.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | 3.1.1 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 1.19.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 3.0.1 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.0 |

### Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ebs_csi_irsa_role"></a> [ebs\_csi\_irsa\_role](#module\_ebs\_csi\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | v6.4.0 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 21.15.1 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | 21.12.0 |
| <a name="module_load_balancer_controller_irsa_role"></a> [load\_balancer\_controller\_irsa\_role](#module\_load\_balancer\_controller\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | v6.4.0 |
| <a name="module_rds"></a> [rds](#module\_rds) | terraform-aws-modules/rds/aws | 7.1.0 |
| <a name="module_rds_proxy"></a> [rds\_proxy](#module\_rds\_proxy) | terraform-aws-modules/rds-proxy/aws | 4.2.1 |
| <a name="module_rds_proxy_sg"></a> [rds\_proxy\_sg](#module\_rds\_proxy\_sg) | terraform-aws-modules/security-group/aws | 5.2 |
| <a name="module_rds_sg"></a> [rds\_sg](#module\_rds\_sg) | terraform-aws-modules/security-group/aws | 5.2.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 6.6.0 |
| <a name="module_vpc_cni_irsa_role"></a> [vpc\_cni\_irsa\_role](#module\_vpc\_cni\_irsa\_role) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts | v6.4.0 |

### Resources

| Name | Type |
|------|------|
| [aws_db_subnet_group.default](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/db_subnet_group) | resource |
| [aws_elasticache_parameter_group.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/elasticache_parameter_group) | resource |
| [aws_elasticache_replication_group.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/elasticache_replication_group) | resource |
| [aws_elasticache_subnet_group.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/elasticache_subnet_group) | resource |
| [aws_iam_role.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/iam_role) | resource |
| [aws_iam_role.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.reducto_storage](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.reducto_storage_lifecycle](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.reducto_storage_public_access_block](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_secretsmanager_secret.superuser](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.superuser](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.reducto_elasticache](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group) | resource |
| [aws_security_group_rule.allow_all_cluster_and_nodes_traffic](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.allow_all_cluster_and_nodes_traffic_ingress](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.allow_all_intra_node_traffic](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.allow_eks_cluster_access_from_vpc](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.webhook_admission_inbound](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.webhook_admission_outbound](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/resources/security_group_rule) | resource |
| [helm_release.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.cert_manager](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.datadog](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.envoy_gateway](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.ingress_nginx](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.karpenter](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.karpenter-crd](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.kube_prometheus_stack](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.kyverno](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.nvidia_device_plugin](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.opentelemetry_collector](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.prometheus_crds](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.reducto](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.telegraf](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [helm_release.vllm_stack](https://registry.terraform.io/providers/hashicorp/helm/3.1.1/docs/resources/release) | resource |
| [kubectl_manifest.agent_sandbox_controller_vap](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_controller_workloads_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_controller_workloads_role](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_core](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_ext](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.agent_sandbox_write_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.cloudflare_api_secret](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.cluster_issuer](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.cluster_issuer_staging](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.cluster_manifests](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.datadog_secret](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.envoy_controller_network_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.envoy_data_plane_network_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.gvisor](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.karpenter_node_class](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.karpenter_node_pool](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.karpenter_sandbox_node_class](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.karpenter_sandbox_node_pool](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.kyverno_prometheus_rules](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.kyverno_require_sandbox_gvisor](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.kyverno_restrict_privileged_hostpath](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.monitoring_ns](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.otel_auth_secret](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.otel_datadog_secret](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_egress_backend](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_egress_backend_tls](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_egress_controller_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_egress_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_egress_route](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_envoy_proxy](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_gateway](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_gateway_class](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.pi_sandbox_client_namespace](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.prometheus_rules](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.sandbox_network_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.staging_to_sandbox_network_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.telegraf](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubectl_manifest.telegraf_sm](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/resources/manifest) | resource |
| [kubernetes_secret_v1.hf_token](https://registry.terraform.io/providers/hashicorp/kubernetes/3.0.1/docs/resources/secret_v1) | resource |
| [random_password.db_password](https://registry.terraform.io/providers/hashicorp/random/3.8.0/docs/resources/password) | resource |
| [random_password.elasticache_auth_token](https://registry.terraform.io/providers/hashicorp/random/3.8.0/docs/resources/password) | resource |
| [random_string.secret_suffix](https://registry.terraform.io/providers/hashicorp/random/3.8.0/docs/resources/string) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/data-sources/availability_zones) | data source |
| [aws_iam_policy_document.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.reducto](https://registry.terraform.io/providers/hashicorp/aws/6.28.0/docs/data-sources/iam_policy_document) | data source |
| [kubectl_file_documents.agent_sandbox_controller_vap](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/data-sources/file_documents) | data source |
| [kubectl_file_documents.agent_sandbox_core](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/data-sources/file_documents) | data source |
| [kubectl_file_documents.agent_sandbox_ext](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/data-sources/file_documents) | data source |
| [kubectl_filename_list.cluster_manifests](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/data-sources/filename_list) | data source |
| [kubectl_filename_list.prometheus_rules](https://registry.terraform.io/providers/gavinbunney/kubectl/1.19.0/docs/data-sources/filename_list) | data source |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_agent_sandbox_write_namespaces"></a> [agent\_sandbox\_write\_namespaces](#input\_agent\_sandbox\_write\_namespaces) | Namespaces the agent-sandbox controller is allowed to create/update pods, PVCs, services, and network policies in. Must include agent-sandbox-system. | `list(string)` | <pre>[<br/>  "agent-sandbox-system",<br/>  "reducto-pi-sandbox"<br/>]</pre> | no |
| <a name="input_cloudflare_api_token"></a> [cloudflare\_api\_token](#input\_cloudflare\_api\_token) | Cloudflare API token for Cert Manager to use DNS solver for issuing TLS certificates | `string` | n/a | yes |
| <a name="input_cluster_endpoint_public_access"></a> [cluster\_endpoint\_public\_access](#input\_cluster\_endpoint\_public\_access) | Enable public access to the EKS cluster API endpoint | `bool` | `true` | no |
| <a name="input_cluster_endpoint_public_access_cidrs"></a> [cluster\_endpoint\_public\_access\_cidrs](#input\_cluster\_endpoint\_public\_access\_cidrs) | List of CIDR blocks allowed to access the public EKS API endpoint | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster and prefix for related resources | `string` | `"reducto-ai"` | no |
| <a name="input_create_pi_sandbox_client_namespace"></a> [create\_pi\_sandbox\_client\_namespace](#input\_create\_pi\_sandbox\_client\_namespace) | Create pi\_sandbox\_client\_namespace (plus an egress NetworkPolicy allowing only sandbox :8888) as a synthetic verification client. Set false when pi\_sandbox\_client\_namespace is an existing application namespace: Terraform must not own (and on teardown delete) it, and the sandbox-only egress policy would cut the app off from DNS and its dependencies. | `bool` | `true` | no |
| <a name="input_datadog_api_key"></a> [datadog\_api\_key](#input\_datadog\_api\_key) | Datadog API key | `string` | `""` | no |
| <a name="input_datadog_site"></a> [datadog\_site](#input\_datadog\_site) | Datadog site | `string` | `"us3.datadoghq.com"` | no |
| <a name="input_db_deletion_protection"></a> [db\_deletion\_protection](#input\_db\_deletion\_protection) | Enable deletion protection for RDS database to prevent accidental deletion | `bool` | `true` | no |
| <a name="input_db_instance_class"></a> [db\_instance\_class](#input\_db\_instance\_class) | Instance class for Reducto Postgres database | `string` | `"db.t4g.medium"` | no |
| <a name="input_db_multi_az"></a> [db\_multi\_az](#input\_db\_multi\_az) | Enable Multi-AZ deployment for RDS database for high availability | `bool` | `true` | no |
| <a name="input_db_username"></a> [db\_username](#input\_db\_username) | Postgres DB username | `string` | `"reducto"` | no |
| <a name="input_elasticache_apply_immediately"></a> [elasticache\_apply\_immediately](#input\_elasticache\_apply\_immediately) | Apply ElastiCache changes immediately instead of waiting for the maintenance window | `bool` | `false` | no |
| <a name="input_elasticache_engine_version"></a> [elasticache\_engine\_version](#input\_elasticache\_engine\_version) | Valkey engine version for the ElastiCache replication group | `string` | `"8.2"` | no |
| <a name="input_elasticache_node_type"></a> [elasticache\_node\_type](#input\_elasticache\_node\_type) | Node type for the ElastiCache replication group | `string` | `"cache.t4g.small"` | no |
| <a name="input_elasticache_port"></a> [elasticache\_port](#input\_elasticache\_port) | Port used by the ElastiCache replication group | `number` | `6379` | no |
| <a name="input_elasticache_replica_count"></a> [elasticache\_replica\_count](#input\_elasticache\_replica\_count) | Number of ElastiCache read replicas; set to at least one for automatic failover and Multi-AZ | `number` | `1` | no |
| <a name="input_elasticache_snapshot_retention_limit"></a> [elasticache\_snapshot\_retention\_limit](#input\_elasticache\_snapshot\_retention\_limit) | Number of days ElastiCache snapshots are retained; set to zero to disable automatic snapshots | `number` | `7` | no |
| <a name="input_enable_agent_sandbox"></a> [enable\_agent\_sandbox](#input\_enable\_agent\_sandbox) | Whether to install the Agent Sandbox controller/CRDs, gVisor RuntimeClass + sandbox NodePool, and the Pi egress gateway substrate. Requires var.enable\_kyverno = true (set it separately) for the require-sandbox-gvisor enforcement policy. | `bool` | `false` | no |
| <a name="input_enable_elasticache"></a> [enable\_elasticache](#input\_enable\_elasticache) | Provision a private, TLS-enabled Amazon ElastiCache for Valkey replication group and wire Reducto to it. Opt in when using the New Reducto Architecture or another Redis-backed feature. | `bool` | `false` | no |
| <a name="input_enable_gpu_managed_node_group"></a> [enable\_gpu\_managed\_node\_group](#input\_enable\_gpu\_managed\_node\_group) | Whether to create the GPU managed node group (system\_gpu) for GPU workloads | `bool` | `false` | no |
| <a name="input_enable_kyverno"></a> [enable\_kyverno](#input\_enable\_kyverno) | Whether to install Kyverno and its cluster policies | `bool` | `false` | no |
| <a name="input_enable_nvidia_device_plugin"></a> [enable\_nvidia\_device\_plugin](#input\_enable\_nvidia\_device\_plugin) | Whether to install the NVIDIA device plugin for GPU support | `bool` | `false` | no |
| <a name="input_enable_otel_collector"></a> [enable\_otel\_collector](#input\_enable\_otel\_collector) | Whether to deploy the OpenTelemetry Collector on the cluster | `bool` | `false` | no |
| <a name="input_enable_reducto"></a> [enable\_reducto](#input\_enable\_reducto) | Whether to deploy the Reducto application via Helm | `bool` | `true` | no |
| <a name="input_enable_vllm_stack"></a> [enable\_vllm\_stack](#input\_enable\_vllm\_stack) | Whether to deploy the vLLM stack on the cluster | `bool` | `false` | no |
| <a name="input_envoy_gateway_chart_version"></a> [envoy\_gateway\_chart\_version](#input\_envoy\_gateway\_chart\_version) | Envoy Gateway Helm chart version (gateway-helm, oci://docker.io/envoyproxy) | `string` | `"v1.8.1"` | no |
| <a name="input_helm_release_timeout"></a> [helm\_release\_timeout](#input\_helm\_release\_timeout) | Timeout in seconds for Helm release operations | `number` | `900` | no |
| <a name="input_kyverno_admission_replicas"></a> [kyverno\_admission\_replicas](#input\_kyverno\_admission\_replicas) | Replicas for the Kyverno admission controller. Its webhooks fail closed (failurePolicy: Fail), so it must be HA: Kyverno requires 1 or an odd number >= 3. | `number` | `3` | no |
| <a name="input_kyverno_chart_version"></a> [kyverno\_chart\_version](#input\_kyverno\_chart\_version) | Kyverno Helm chart version | `string` | `"3.9.0"` | no |
| <a name="input_otel_auth_token"></a> [otel\_auth\_token](#input\_otel\_auth\_token) | Auth token used by the OpenTelemetry collector | `string` | `""` | no |
| <a name="input_otel_datadog_api_key"></a> [otel\_datadog\_api\_key](#input\_otel\_datadog\_api\_key) | Datadog API key used by the OpenTelemetry collector exporter | `string` | `"admin"` | no |
| <a name="input_otel_host"></a> [otel\_host](#input\_otel\_host) | FQDN for exposing the OpenTelemetry Collector | `string` | `""` | no |
| <a name="input_pi_egress_controller_namespace"></a> [pi\_egress\_controller\_namespace](#input\_pi\_egress\_controller\_namespace) | Namespace containing the Envoy Gateway control plane for the Pi egress stack | `string` | `"reducto-pi-egress-system"` | no |
| <a name="input_pi_egress_namespace"></a> [pi\_egress\_namespace](#input\_pi\_egress\_namespace) | Namespace containing the Envoy data plane and edge Gateway/routes for the Pi egress stack | `string` | `"reducto-pi-egress"` | no |
| <a name="input_pi_sandbox_client_namespace"></a> [pi\_sandbox\_client\_namespace](#input\_pi\_sandbox\_client\_namespace) | Namespace whose workloads are allowed to reach the sandbox runtime port (e.g. the Reducto API's namespace). | `string` | `"reducto-pi-sandbox-client"` | no |
| <a name="input_pi_sandbox_namespace"></a> [pi\_sandbox\_namespace](#input\_pi\_sandbox\_namespace) | Namespace where sandbox runtime pods (SandboxClaims) are created. Must be listed in agent\_sandbox\_write\_namespaces. | `string` | `"reducto-pi-sandbox"` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | List of private subnets CIDRs | `list(string)` | `[]` | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | List of public subnets CIDRs | `list(string)` | `[]` | no |
| <a name="input_reducto_extra_values_files"></a> [reducto\_extra\_values\_files](#input\_reducto\_extra\_values\_files) | Paths to additional Helm values files layered last. Use this for deployment-specific queue worker settings. | `list(string)` | `[]` | no |
| <a name="input_reducto_helm_chart"></a> [reducto\_helm\_chart](#input\_reducto\_helm\_chart) | Path to Helm Chart on OCI registry | `string` | `"oci://registry.reducto.ai/reducto-api/reducto"` | no |
| <a name="input_reducto_helm_chart_version"></a> [reducto\_helm\_chart\_version](#input\_reducto\_helm\_chart\_version) | Reducto Helm Chart version | `string` | `"1.12.6"` | no |
| <a name="input_reducto_helm_repo_password"></a> [reducto\_helm\_repo\_password](#input\_reducto\_helm\_repo\_password) | Password for Helm Registry for Reducto Helm Chart | `string` | n/a | yes |
| <a name="input_reducto_helm_repo_username"></a> [reducto\_helm\_repo\_username](#input\_reducto\_helm\_repo\_username) | Username for Helm Registry for Reducto Helm Chart | `string` | n/a | yes |
| <a name="input_reducto_host"></a> [reducto\_host](#input\_reducto\_host) | Full host DNS for Reducto (Example: reducto.mydomain.com) | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region where resources will be created | `string` | `"us-east-1"` | no |
| <a name="input_sandbox_ami_id"></a> [sandbox\_ami\_id](#input\_sandbox\_ami\_id) | AMI ID for reducto-sandbox Karpenter nodes, built by the internal image pipeline with gVisor (runsc + containerd-shim-runsc-v1) baked in at sandbox\_runsc\_path. Must be an AL2023-based EKS image (nodeadm bootstrap) for the cluster's Kubernetes version. Required when enable\_agent\_sandbox = true. | `string` | `""` | no |
| <a name="input_sandbox_blocked_egress_cidrs"></a> [sandbox\_blocked\_egress\_cidrs](#input\_sandbox\_blocked\_egress\_cidrs) | Extra CIDRs the Envoy egress data plane must never reach on behalf of sandbox pods (sandbox pods themselves have no IP egress), on top of RFC1918, 100.64.0.0/10 (CGNAT, used by EKS custom networking pod CIDRs), 169.254.0.0/16 (link-local/IMDS), var.vpc\_cidr, the subnet CIDRs, and the cluster service CIDR. Add secondary VPC CIDRs, peered VPCs, or on-prem ranges here. | `list(string)` | `[]` | no |
| <a name="input_sandbox_egress_allow"></a> [sandbox\_egress\_allow](#input\_sandbox\_egress\_allow) | In-cluster destinations sandbox pods may reach, as namespace + port (e.g. [{ namespace = "reducto", port = 80 }] for the Reducto API). Namespace-scoped by design: cannot name VPC or public addresses. | <pre>list(object({<br/>    namespace = string<br/>    port      = number<br/>    protocol  = optional(string, "TCP")<br/>  }))</pre> | `[]` | no |
| <a name="input_sandbox_egress_allowlist"></a> [sandbox\_egress\_allowlist](#input\_sandbox\_egress\_allowlist) | Public hosts sandbox pods may reach, only via the Envoy egress proxy (HTTP\_PROXY=http://reducto-pi-egress.<pi\_egress\_namespace>:80). Each entry renders a Backend + BackendTLSPolicy + HTTPRoute in pi\_egress\_namespace: Envoy terminates the sandbox's plain-HTTP proxy request and originates TLS to host:port (system CAs). Anything not listed gets no route (404). Empty = sandbox has no public egress at all. | <pre>list(object({<br/>    host = string<br/>    port = optional(number, 443)<br/>  }))</pre> | `[]` | no |
| <a name="input_sandbox_managed_node_group"></a> [sandbox\_managed\_node\_group](#input\_sandbox\_managed\_node\_group) | Sizing for the reducto-sandbox EKS managed node group (only used when sandbox\_node\_provisioner = "managed\_node\_group"). On-demand only. | <pre>object({<br/>    instance_types = optional(list(string), ["m7i.xlarge", "m7i.2xlarge"])<br/>    min_size       = optional(number, 0)<br/>    max_size       = optional(number, 10)<br/>    desired_size   = optional(number, 1)<br/>    disk_size_gb   = optional(number, 150)<br/>  })</pre> | `{}` | no |
| <a name="input_sandbox_node_provisioner"></a> [sandbox\_node\_provisioner](#input\_sandbox\_node\_provisioner) | How reducto-sandbox nodes are provisioned: "karpenter" (NodePool + EC2NodeClass in karpenter.tf) or "managed\_node\_group" (EKS managed node group in eks.tf, for clusters that do not run Karpenter). Both boot sandbox\_ami\_id with the same node-type label and reducto.ai/sandbox taint. | `string` | `"karpenter"` | no |
| <a name="input_sandbox_runsc_path"></a> [sandbox\_runsc\_path](#input\_sandbox\_runsc\_path) | Path of the runsc binary inside sandbox\_ami\_id (containerd-shim-runsc-v1 must be on containerd's PATH in the same image). | `string` | `"/usr/local/bin/runsc"` | no |
| <a name="input_slack_webhook_url"></a> [slack\_webhook\_url](#input\_slack\_webhook\_url) | Slack Webhook URL for Alertmanager | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to AWS resources, including organization-required cost, environment, and ownership tags | `map(string)` | `{}` | no |
| <a name="input_vllm_stack_hf_token"></a> [vllm\_stack\_hf\_token](#input\_vllm\_stack\_hf\_token) | Hugging Face API token used by the vLLM stack for model access | `string` | `""` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | CIDR block for the VPC | `string` | `"10.125.0.0/16"` | no |

### Outputs

| Name | Description |
|------|-------------|
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data required to communicate with the cluster |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Endpoint for EKS control plane |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the EKS cluster |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Security group ID attached to the EKS cluster |
| <a name="output_configure_kubectl"></a> [configure\_kubectl](#output\_configure\_kubectl) | Command to configure kubectl for the EKS cluster |
| <a name="output_db_instance_endpoint"></a> [db\_instance\_endpoint](#output\_db\_instance\_endpoint) | Connection endpoint for the RDS instance |
| <a name="output_db_instance_name"></a> [db\_instance\_name](#output\_db\_instance\_name) | Name of the RDS database |
| <a name="output_db_proxy_arn"></a> [db\_proxy\_arn](#output\_db\_proxy\_arn) | ARN of the RDS Proxy |
| <a name="output_db_proxy_endpoint"></a> [db\_proxy\_endpoint](#output\_db\_proxy\_endpoint) | Connection endpoint for the RDS Proxy |
| <a name="output_elasticache_primary_endpoint"></a> [elasticache\_primary\_endpoint](#output\_elasticache\_primary\_endpoint) | Primary endpoint for the managed Valkey replication group |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the OIDC Provider for EKS |
| <a name="output_private_subnets"></a> [private\_subnets](#output\_private\_subnets) | List of IDs of private subnets |
| <a name="output_public_subnets"></a> [public\_subnets](#output\_public\_subnets) | List of IDs of public subnets |
| <a name="output_reducto_host"></a> [reducto\_host](#output\_reducto\_host) | Hostname where Reducto is accessible |
| <a name="output_reducto_iam_role_arn"></a> [reducto\_iam\_role\_arn](#output\_reducto\_iam\_role\_arn) | ARN of the IAM role for Reducto service account |
| <a name="output_region"></a> [region](#output\_region) | AWS region where resources are deployed |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | ARN of the S3 bucket for Reducto storage |
| <a name="output_s3_bucket_name"></a> [s3\_bucket\_name](#output\_s3\_bucket\_name) | Name of the S3 bucket for Reducto storage |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC |
<!-- END_TF_DOCS -->

## Helm Chart

To obtain or inspect Helm Chart and available configurations in `values.yaml`

```
# Login
helm registry login registry.reducto.ai \
    --username <your-username>  \
    --password <your-password>

# Get latest Helm Chart
helm pull oci://registry.reducto.ai/reducto-api/reducto
```


## Security

All worklods are only created in private subnet, including NLB for ingress-nginx.

For bootstrapping of the cluster both public and private endpoints are enabled, public endpoint access can be restricted or removed after provisioning:

1. Remove public endpoint `cluster_endpoint_public_access = false`.
2. Restrict public endpoint `cluster_endpoint_public_access_cidrs = [ vpc_cidr ]`


### Terraform State

To use a bucket for Terraform state, create a bucket and update `backend.tf`.

OR you can skip this to quickly run Terraform plan and apply with locally managed `terraform.tfstate` state file for testing purposes.

### Configuration

Make sure `variables.tf` has configuration that you desire, like restricting EKS public endpoint, avoiding VPC CIDR collisions, or database instance type.

Create `terraform.tfvars` with following contents:

```
reducto_helm_repo_username = "todo"
reducto_helm_repo_password = "todo"
reducto_host = "reducto.example.com"
cloudflare_api_token = "token"

# For alerting
slack_webhook_url = "todo"
```

### Provisioning

Apply Terraform

```
terraform init
terraform plan
terraform apply
```

### Configure Cloudflare DNS

Cloudflare DNS is used to obtain TLS certificate from Letsencrypt via [cert-manager using dns01 solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/).

Check the private LB hostname created by cluster for Nginx Ingress Controller and use it to create CNAME DNS record on Cloudflare to point to value provided in `reducto_host`.

### Access Reducto

Reducto will be accessible on ingress-nginx NLB via hostname configured in `reducto_host`

For checking Reducto service health without public endpoint: port forward your local 4567 to Reducto service:

```
kubectl port-forward service/reducto-reducto-http 4567:80 -n reducto

# Access Reducto
curl localhost:4567
```

## New AWS account

For Karpenter to [request spot instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/service-linked-roles-spot-instance-requests.html), create the service-linked role:

```sh
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

## Notes on Destroy

To `terraform destroy`, comment out the `lifecycle` block in `reducto-bucket.tf` and remove deletion protection from DB.

You can remove deletion protection by setting `var.db_deletion_protection = false` and `terraform apply`.

`terraform destroy` may not finish because VPC will contain resources created outside of Terraform managment:
- NLB for nginx controller created by AWS load balancer controller
- EKS Nodes from autoscaling by Karpenter
- Bucket not empty

So along side `terraform destroy` you'll need to manually delete above resources from AWS console.

## Notes on NLB for Nginx

To customize NLB configuration:
- See [AWS Load Balancer controller annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/) for Service, and [Ingress Nginx Helm Chart](https://github.com/kubernetes/ingress-nginx/tree/helm-chart-4.11.2/charts/ingress-nginx) configuration.
- For [NLB TLS Termination](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/use_cases/nlb_tls_termination/) with ACM ssl cert (without cert-manager), configure target port in `values/ingress-nginx-controller.yaml`.
   ```
   service:
     targetPorts:
       https: http
   ```

## Monitoring

Reducto internal job queue length is a good indicator of overall worker health. And 5xx metric from Reducto ingress is a good indicator of API health.

`PrometheusRule` in `manifests/prometheus/rules/01-reducto.yaml` monitors internal queue length and 5xx metrics. When queue doesn't go down for a long duration OR API returns 5xx status for a long duration, alerts are sent to configured Slack channel.
