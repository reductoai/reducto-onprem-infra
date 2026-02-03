# Upgrade

## From 1.8.0 to 1.9.0

This release upgrades the EKS cluster from Kubernetes 1.34 to 1.35 and updates all related EKS add-ons to their latest compatible versions. It also adds priority class configuration for Prometheus and Alertmanager components.

### Changes

**Kubernetes Version**

- Upgraded from 1.34 to 1.35

**EKS Add-on Updates**

| Add-on | Previous Version | New Version |
|--------|-----------------|-------------|
| kube-proxy | v1.34.1-eksbuild.2 | v1.35.0-eksbuild.2 |
| vpc-cni | v1.21.1-eksbuild.1 | v1.21.1-eksbuild.3 |
| aws-ebs-csi-driver | v1.54.0-eksbuild.1 | v1.55.0-eksbuild.1 |

Note: Other add-ons (CoreDNS, Pod Identity Agent) remain at their previous versions as they are compatible with Kubernetes 1.35.

**EKS Managed Node Groups**

- Updated system node AMI release version from `1.34.2-20260120` to `1.35.0-20260129`
- Updated system_gpu node AMI release version from `1.34.2-20260120` to `1.35.0-20260129`

**Monitoring Stack Improvements**

- Added `priorityClassName: system-cluster-critical` to Prometheus and Alertmanager StatefulSets
- Ensures monitoring components are protected during node pressure and evictions
- Improves cluster observability during high resource utilization scenarios

**Documentation Updates**

- Updated CLAUDE.md to reflect Kubernetes 1.35
- Improved formatting and readability in CLAUDE.md

### Manual Steps

No manual steps required. The upgrade is handled automatically by Terraform.

### Important Notes

- The upgrade process is handled automatically by Terraform
- EKS will perform a rolling upgrade of the control plane
- Add-ons will be updated after the control plane upgrade completes
- Node groups will continue running during the control plane upgrade
- Minimal downtime is expected for the control plane during the upgrade
- The priority class changes only affect new or restarted Prometheus/Alertmanager pods

## From 1.7.0 to 1.8.0

This release upgrades the RDS infrastructure to use the latest RDS Terraform module and PostgreSQL major version, bringing significant new features and improved security for database credentials.

### Changes

**RDS Module Upgrade**

- RDS Terraform module: 6.10.0 → 7.1.0 (major version upgrade)
- Minimum Terraform version requirement: 1.11+ (for write-only attribute support)
- Minimum AWS provider requirement: 6.27+

**PostgreSQL Engine Upgrade**

- PostgreSQL engine: 16.6 → 17.7 (major version upgrade)
- Parameter group family: postgres16 → postgres17
- Major engine version: 16 → 17

**Security Improvements**

- Migrated from `password` to `password_wo` (write-only password parameter)
- Passwords are no longer stored in Terraform state files
- Added `password_wo_version` parameter for password rotation tracking

**Configuration Changes**

- Added commented-out `allow_major_version_upgrade` flag (must be uncommented to perform major version upgrade)
- Updated .gitignore to cover additional Terraform state file patterns

### Manual Steps

**1. Verify Prerequisites**

Ensure your Terraform and AWS provider versions meet the new requirements:

```bash
terraform version  # Must be >= 1.11
```

Check your `versions.tf` or provider configuration to ensure AWS provider is >= 6.27.

**2. Backup Your Database**

Before performing the upgrade, create a manual snapshot of your RDS instance:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier <your-cluster-name> \
  --db-snapshot-identifier <your-cluster-name>-pre-v1-8-0-$(date +%Y%m%d-%H%M%S)
```

**3. Enable Major Version Upgrade**

Edit `reducto-db.tf` and uncomment the `allow_major_version_upgrade` line:

```hcl
# Change this:
#allow_major_version_upgrade = true

# To this:
allow_major_version_upgrade = true
```

**4. Apply the Upgrade**

```bash
terraform init -upgrade  # Update to new module versions
terraform plan          # Review the changes carefully
terraform apply         # Execute the upgrade
```

**5. Monitor the Upgrade**

The upgrade process will take time depending on your database size. Monitor progress:

```bash
aws rds describe-db-instances \
  --db-instance-identifier <your-cluster-name> \
  --query 'DBInstances[0].[DBInstanceStatus,EngineVersion]' \
  --output table
```

**6. Post-Upgrade Verification**

After the upgrade completes:

```bash
# Verify PostgreSQL version
aws rds describe-db-instances \
  --db-instance-identifier <your-cluster-name> \
  --query 'DBInstances[0].EngineVersion' \
  --output text

# Test application connectivity
kubectl port-forward service/reducto-reducto-http 4567:80 -n reducto
# Test your application endpoints
```

**7. Disable Major Version Upgrade Flag (Optional)**

After the upgrade succeeds, you may want to comment out the `allow_major_version_upgrade` flag again to prevent accidental major version upgrades in the future:

```hcl
#allow_major_version_upgrade = true
```

Then run `terraform apply` to update the configuration.

### Important Notes

**Downtime Considerations**

- **Multi-AZ Disabled (`db_multi_az = false`)**: Expect **10-30 minutes of downtime** during the upgrade. The database will be unavailable while the instance is upgraded and rebooted.

- **Multi-AZ Enabled (`db_multi_az = true`)**: Expect **minimal downtime** (typically 1-2 minutes). The upgrade process:
  1. Upgrades the standby instance first
  2. Performs a failover to the upgraded standby (brief downtime here)
  3. Upgrades the former primary instance

  The actual downtime is limited to the failover duration, but the entire upgrade process may take 30-60 minutes.

**RDS Module v7.x Breaking Changes**

- **Write-only passwords**: The `password` parameter is replaced by `password_wo` and `password_wo_version`. Passwords are no longer stored in Terraform state, improving security.
- **Terraform 1.11+ required**: The write-only attribute feature requires Terraform 1.11 or later.
- **AWS Provider 6.27+ required**: The module requires AWS provider version 6.27 or later.

**Rollback Considerations**

- **Major version downgrades are not supported** by AWS RDS. Once upgraded to PostgreSQL 17, you cannot downgrade back to PostgreSQL 16.
- If issues occur, you must restore from a snapshot taken before the upgrade.
- Restoring from snapshot will result in data loss for any transactions that occurred after the snapshot was taken.

## From 1.6.0 to 1.7.0

This release improves infrastructure reliability through pinned dependency versions, better resource ordering, and optimized autoscaling configuration.

### Changes

**Terraform Provider and Module Versions**

All Terraform providers and modules have been pinned to exact versions (removing `~>` constraints):

| Provider/Module | Version |
|----------------|---------|
| AWS Provider | 6.28.0 |
| Helm Provider | 3.1.1 |
| Kubectl Provider | 1.19.0 |
| Kubernetes Provider | 3.0.1 |
| Random Provider | 3.8.0 |
| Null Provider | 3.2.4 |
| VPC Module | 6.6.0 |
| RDS Module | 6.10.0 |
| Security Group Module | 5.2.0 |
| RDS Proxy Module | 4.2.1 |

**EKS Add-on Configuration**

- Added `before_compute = true` to critical EKS add-ons (eks-pod-identity-agent, kube-proxy, vpc-cni)
- Ensures add-ons are fully ready before managed node groups are created
- Improves cluster bootstrap reliability

**Resource Dependencies**

- cert-manager now depends on Karpenter NodePool to ensure proper resource ordering
- Telegraf now depends on kube-prometheus-stack to avoid timing issues
- Disabled CRD retention on cert-manager uninstall (`crds.keep: false`)

**Karpenter Configuration**

- Increased node consolidation delay from 5 seconds to 3 minutes
- Allows nodes to stabilize before consolidation decisions
- Reduces unnecessary node churn in production environments

### Manual Steps

No manual steps required. The upgrade is handled automatically by Terraform.

### Important Notes

- **Terraform Plan Warning**: When running `terraform plan`, you may see EKS add-ons showing as updated with `before_compute` changes. These updates are metadata-only and will **not cause any downtime** or pod restarts. The add-ons themselves are not being recreated, only their configuration is being updated in Terraform state.
- Pinning exact versions provides better reproducibility and prevents unexpected updates
- The `before_compute` flag is a Terraform-only configuration that affects resource creation order
- Karpenter consolidation timing change only affects future consolidation decisions

## From 1.5.0 to 1.6.0

This release upgrades multiple Helm charts to their latest versions, including a major version upgrade for the AWS Load Balancer Controller and significant updates to monitoring components.

### Changes

**Helm Chart Updates**

| Chart | Previous Version | New Version | App Version Change |
|-------|-----------------|-------------|--------------------|
| aws-load-balancer-controller | 1.11.0 | 3.0.0 | v2.11.0 → v3.0.0 |
| cert-manager | v1.15.3 | v1.19.2 | v1.15.3 → v1.19.2 |
| ingress-nginx | 4.11.2 | 4.14.1 | 1.11.2 → 1.14.1 |
| keda | 2.15.0 | 2.18.3 | 2.15.0 → 2.18.3 |
| kube-prometheus-stack | 72.2.0 | 81.2.2 | v0.82.0 → v0.88.0 |
| prometheus-operator-crds | 20.0.0 | 26.0.0 | v0.82.0 → v0.88.0 |

**Storage Configuration**

- Added default GP3 topology-aware StorageClass (`gp3-topology-aware`)
- Removed hardcoded `gp2` storage class references from Prometheus and vLLM configurations
- StorageClass now uses `WaitForFirstConsumer` binding mode for topology awareness

**Infrastructure**

- Added `cluster-manifests.tf` to automatically apply manifests from `manifests/cluster/` directory

### Manual Steps

**Prometheus StatefulSet Update**

The Prometheus Operator upgrade may require deleting the existing Prometheus StatefulSet if the upgrade gets stuck:

```bash
kubectl delete sts prometheus-prometheus-stack-kube-prom-prometheus -n monitoring
```

The StatefulSet will be automatically recreated by the Prometheus Operator with the updated configuration. Prometheus data will be preserved as the PersistentVolumeClaim remains intact.

### Important Notes

- **AWS Load Balancer Controller v3.0.0** requires Kubernetes 1.22+ (cluster is on 1.34 ✓)
- Helm chart version now aligns with controller version (was chart v1.x, now v3.x)
- Gateway API support is now Generally Available (GA)
- All breaking changes have been reviewed and configurations are compatible
- Storage class changes only affect new PVC creation; existing volumes remain unchanged

## From 1.4.0 to 1.5.0

This release adds conditional resource deployment, updates Terraform providers, upgrades the Reducto application, and improves Karpenter node lifecycle management.

### Changes

**Conditional Resource Deployment**

- Added `enable_gpu_managed_node_group` variable (default: false) to make GPU managed node group (system_gpu) optional
- Added `enable_reducto` variable (default: true) to make Reducto Helm release deployment optional
- Converted eks_managed_node_groups to use merge() with conditional expression for GPU nodes

**Application Updates**

- Updated Reducto Helm chart version from 1.9.55 to 1.11.32

**Terraform Provider Updates**

| Provider | Previous Version | New Version |
|----------|-----------------|-------------|
| Helm | 2.17.0 | 3.1.1 |
| Kubernetes | 2.33.0 | 3.0.1 |
| Random | 3.6.3 | 3.8.0 |
| Null | 3.2.3 | 3.2.4 |

**Provider Configuration Changes**

- Fixed Helm and Kubernetes provider block syntax (changed to use `=` for block assignments)
- Migrated deprecated `kubernetes_secret` to `kubernetes_secret_v1` in vllm-stack.tf

**Karpenter Configuration Updates**

- Set `expireAfter: Never` to prevent automatic node expiration
- Added `terminationGracePeriod: 1h` for graceful workload migration during node termination
- Removed instance-family restriction to allow broader instance type selection (previously restricted to c5d, c5n, c6a, c6i, c6in)

### Manual Steps

No manual steps required. The upgrade is handled automatically by Terraform.

### Important Notes

- The GPU managed node group is now disabled by default. Set `enable_gpu_managed_node_group = true` to enable it.
- Reducto deployment remains enabled by default. Set `enable_reducto = false` to disable it.
- Provider upgrades may require running `terraform init -upgrade` to download new provider versions
- Karpenter nodes will no longer automatically expire, improving stability for long-running workloads

## From 1.3.0 to 1.4.0

This release upgrades the EKS cluster from Kubernetes 1.33 to 1.34 and updates the kube-proxy add-on and EKS managed node AMI versions.

### Changes

**Kubernetes Version**

- Upgraded from 1.33 to 1.34

**EKS Add-on Updates**

| Add-on | Previous Version | New Version |
|--------|-----------------|-------------|
| kube-proxy | v1.33.7-eksbuild.2 | v1.34.1-eksbuild.2 |

Note: Other add-ons (CoreDNS, VPC CNI, EBS CSI Driver, Pod Identity Agent) remain at their previous versions as they are compatible with Kubernetes 1.34.

**EKS Managed Node Groups**

- Updated system node AMI release version from `1.33.5-20260120` to `1.34.2-20260120`
- Updated system_gpu node AMI release version from `1.33.5-20260120` to `1.34.2-20260120`

### Manual Steps

No manual steps required. The upgrade is handled automatically by Terraform.

### Important Notes

- The upgrade process is handled automatically by Terraform
- EKS will perform a rolling upgrade of the control plane
- Add-ons will be updated after the control plane upgrade completes
- Node groups will continue running during the control plane upgrade
- Minimal downtime is expected for the control plane during the upgrade

## From 1.2.0 to 1.3.0

This release upgrades the EKS cluster from Kubernetes 1.32 to 1.33 and updates all related EKS add-ons to their latest compatible versions.

### Changes

**Kubernetes Version**

- Upgraded from 1.32 to 1.33

**EKS Add-on Updates**

| Add-on | Previous Version | New Version |
|--------|-----------------|-------------|
| CoreDNS | v1.11.4-eksbuild.24 | v1.13.1-eksbuild.1 |
| eks-pod-identity-agent | v1.3.4-eksbuild.1 | v1.3.10-eksbuild.2 |
| kube-proxy | v1.32.9-eksbuild.2 | v1.33.7-eksbuild.2 |
| VPC CNI | v1.20.4-eksbuild.1 | v1.21.1-eksbuild.1 |
| EBS CSI Driver | v1.37.0-eksbuild.1 | v1.54.0-eksbuild.1 |

**EKS Managed Node Groups**

- Updated system node AMI release version from `1.32.9-20260120` to `1.33.5-20260120`
- Updated system_gpu node AMI release version from `1.32.9-20260120` to `1.33.5-20260120`

### Manual Steps

No manual steps required. The upgrade is handled automatically by Terraform.

### Important Notes

- The upgrade process is handled automatically by Terraform
- EKS will perform a rolling upgrade of the control plane
- Add-ons will be updated after the control plane upgrade completes
- Node groups will continue running during the control plane upgrade
- Minimal downtime is expected for the control plane during the upgrade

## From 1.1.0 to 1.2.0

This release upgrades the AWS provider to 6.0 and Karpenter to v1.8, with additional infrastructure improvements.

### Changes

**AWS Provider & Karpenter**

- Upgraded AWS provider from 5.92.0 to 6.28.0 (breaking: AWS provider 6.0)
- Upgraded Karpenter from v1.2.1 to v1.8.3 with separate CRD management
- Upgraded terraform-aws-modules/eks Karpenter module from 20.33.1 to 21.12.0

**EKS Managed Node Groups**

- Pinned AMI release version to `1.32.9-20260120` for system node groups
- Enabled detailed monitoring for all managed node groups
- Removed startup node group (no longer needed for bootstrap capacity)

**Karpenter**

- Migrated from Bottlerocket OS (`bottlerocket@v1.29.0`) to Amazon Linux 2023 (`al2023@v20260120`)
- Updated storage configuration to use single 200Gi volume instead of dual volume setup
- Enabled detailed monitoring for Karpenter managed nodes

### Manual Steps

**Required: Label and annotate Karpenter CRDs for Helm management**

Before running `terraform apply`, label and annotate the existing Karpenter CRDs so they can be managed by the new karpenter-crd Helm release:

```bash
kubectl label crd ec2nodeclasses.karpenter.k8s.aws app.kubernetes.io/managed-by=Helm
kubectl annotate crd ec2nodeclasses.karpenter.k8s.aws meta.helm.sh/release-name=karpenter-crd
kubectl annotate crd ec2nodeclasses.karpenter.k8s.aws meta.helm.sh/release-namespace=kube-system

kubectl label crd nodeclaims.karpenter.sh app.kubernetes.io/managed-by=Helm
kubectl annotate crd nodeclaims.karpenter.sh meta.helm.sh/release-name=karpenter-crd
kubectl annotate crd nodeclaims.karpenter.sh meta.helm.sh/release-namespace=kube-system

kubectl label crd nodepools.karpenter.sh app.kubernetes.io/managed-by=Helm
kubectl annotate crd nodepools.karpenter.sh meta.helm.sh/release-name=karpenter-crd
kubectl annotate crd nodepools.karpenter.sh meta.helm.sh/release-namespace=kube-system
```

### Important Notes

- The startup node group will be removed, but system node group capacity provides sufficient bootstrap capacity
- Pinning AMI versions prevents unexpected node updates and provides better stability

## From 1.0.0 to 1.1.0

This release upgrades the EKS cluster from Kubernetes 1.31 to 1.32, updates all related EKS add-ons, and includes configuration improvements for easier infrastructure teardown and development workflows.

### Changes

**Kubernetes Version**

- Upgraded from 1.31 to 1.32

**EKS Add-on Updates**

| Add-on | Previous Version | New Version |
|--------|-----------------|-------------|
| CoreDNS | v1.11.3-eksbuild.1 | v1.11.4-eksbuild.24 |
| kube-proxy | v1.30.3-eksbuild.9 | v1.32.9-eksbuild.2 |
| VPC CNI | v1.18.5-eksbuild.1 | v1.20.4-eksbuild.1 |
| EBS CSI Driver | v1.36.0-eksbuild.1 | v1.37.0-eksbuild.1 |
| Pod Identity Agent | v1.3.2-eksbuild.2 | v1.3.4-eksbuild.1 |

**OpenTelemetry Collector**

- Fixed configuration to use proper Terraform variable reference (`var.otel_auth_token`) instead of environment variable placeholder

**Telegraf**

- Disabled PodDisruptionBudget to allow easier pod eviction during development and teardown operations

### Manual Steps

If node update process gets stuck, you might have to manually delete `telegraf` pods because of nonpermissive PodDisruptionBudget:

```bash
kubectl delete pod -n monitoring -l app.kubernetes.io/name=telegraf
```

### Important Notes

- The upgrade process is handled automatically by Terraform
- EKS will perform a rolling upgrade of the control plane
- Add-ons will be updated after the control plane upgrade completes
- Node groups will continue running during the control plane upgrade
- Minimal downtime is expected for the control plane during the upgrade
