# Upgrade

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
