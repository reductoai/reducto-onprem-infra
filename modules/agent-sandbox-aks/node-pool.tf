# Dedicated AKS Pod Sandboxing pool. Each pod that uses the Kata handler runs
# in its own lightweight VM (Hyper-V + Cloud Hypervisor) with its own guest
# kernel — the on-prem AKS equivalent of hosted gVisor.
#
# Requirements (Microsoft Learn, "Pod sandboxing with AKS",
# https://learn.microsoft.com/azure/aks/use-pod-sandboxing, updated 2026-10-20):
#   - workload runtime KataVmIsolation (the preview name was KataMshvVmIsolation
#     with RuntimeClass kata-mshv-vm-isolation; the GA name is used here)
#   - os SKU AzureLinux (Ubuntu and Windows unsupported)
#   - a generation 2 VM size with nested virtualization; no Arm64
#   - no FIPS and no Trusted Launch on the pool
#   - Kubernetes 1.27+
# Microsoft's "existing cluster" procedure runs `az aks update -g <rg> -n
# <cluster>` once after adding the pool "to reconcile the cluster
# configuration". Terraform cannot express a no-op reconcile; the install doc
# lists it as a manual step after the first apply.
#
# Label and taint match the hosted reducto-sandbox NodePool
# (node-type=reducto-sandbox, reducto.ai/sandbox=true:NoSchedule), so only pods
# that tolerate the taint — the sandbox pods, via the RuntimeClass scheduling
# block — and DaemonSets land here.
resource "azurerm_kubernetes_cluster_node_pool" "sandbox" {
  name                  = var.node_pool_name
  kubernetes_cluster_id = data.azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  os_type          = "Linux"
  os_sku           = "AzureLinux"
  workload_runtime = "KataVmIsolation"
  vm_size          = var.node_vm_size

  auto_scaling_enabled = true
  min_count            = var.node_min_count
  max_count            = var.node_max_count
  max_pods             = var.node_max_pods

  os_disk_size_gb      = var.node_os_disk_size_gb
  zones                = length(var.node_zones) > 0 ? var.node_zones : null
  vnet_subnet_id       = var.node_vnet_subnet_id
  pod_subnet_id        = var.node_pod_subnet_id
  orchestrator_version = var.node_orchestrator_version

  node_labels = local.sandbox_node_labels
  node_taints = ["${var.node_taint_key}=true:NoSchedule"]

  # AKS has no do-not-disrupt equivalent: an upgrade drains each node, which
  # ends the claimed sessions on it. The surge node lets the warm pool refill
  # before the old node goes; run upgrades of this pool at low traffic.
  upgrade_settings {
    max_surge                = var.node_upgrade_max_surge
    drain_timeout_in_minutes = var.node_upgrade_drain_timeout_minutes
  }

  tags = var.tags

  lifecycle {
    # The cluster autoscaler owns the live count.
    ignore_changes = [node_count]

    precondition {
      condition     = var.node_min_count <= var.node_max_count
      error_message = "node_min_count must be <= node_max_count."
    }
    # Microsoft's sizing guidance: Arm64 is not supported with Pod Sandboxing.
    # Azure Arm64 sizes carry a "p" after the vCPU count (e.g. D4ps_v5).
    precondition {
      condition     = !can(regex("^Standard_[A-Za-z]+[0-9]+[a-z]*p[a-z]*_v[0-9]+$", var.node_vm_size))
      error_message = "node_vm_size ${var.node_vm_size} looks like an Arm64 size; Pod Sandboxing needs a generation 2 x86-64 size with nested virtualization (e.g. Standard_D16s_v5)."
    }
  }
}
