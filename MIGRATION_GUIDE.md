# Kubernetes Version Upgrade Guide

## Overview

This guide covers upgrading your EKS cluster from Kubernetes 1.31 to 1.32.

## Changes

### Kubernetes Version
- **From:** 1.31
- **To:** 1.32

### EKS Add-on Version Updates

| Add-on | Previous Version | New Version |
|--------|-----------------|-------------|
| CoreDNS | v1.11.3-eksbuild.1 | v1.11.4-eksbuild.24 |
| kube-proxy | v1.30.3-eksbuild.9 | v1.32.6-eksbuild.13 |
| VPC CNI | v1.18.5-eksbuild.1 | v1.20.4-eksbuild.1 |
| EBS CSI Driver | v1.36.0-eksbuild.1 | v1.37.0-eksbuild.1 |
| Pod Identity Agent | v1.3.2-eksbuild.2 | v1.3.4-eksbuild.1 |

## Migration Steps

1. **Review the changes**
   ```bash
   git diff main
   ```

2. **Plan the upgrade**
   ```bash
   terraform plan
   ```

3. **Apply the upgrade**
   ```bash
   terraform apply
   ```

4. **Verify cluster health**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

## Notes

- The upgrade process is handled automatically by Terraform
- EKS will perform a rolling upgrade of the control plane
- Add-ons will be updated after the control plane upgrade completes
- Node groups will continue running during the control plane upgrade
- Minimal downtime is expected for the control plane during the upgrade

## Rollback

If issues occur, you can rollback by reverting the changes and running `terraform apply` again with the previous versions.
