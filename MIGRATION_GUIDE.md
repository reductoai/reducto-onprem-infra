# Upgrade

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
