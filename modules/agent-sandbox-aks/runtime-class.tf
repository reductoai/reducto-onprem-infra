# RuntimeClass for the sandbox pods, on the AKS Kata handler.
#
# AKS ships a built-in `kata-vm-isolation` RuntimeClass. Microsoft documents
# custom classes on the same handler (`handler: kata`) for tuned overhead
# (https://learn.microsoft.com/azure/aks/considerations-pod-sandboxing). This
# one also carries the sandbox pool's nodeSelector and toleration, the hosted
# gvisor pattern: the chart then sets only runtimeClassName, and the
# RuntimeClass admission plugin adds the scheduling constraints to each pod.
#
# Sizing on Kata (same page): the pod MEMORY LIMIT is the fixed size of the pod
# VM, and the VM's memory is taken from the node for the pod's lifetime, so
# idle warm-pool pods are not overcommitted the way gVisor pods are. CPU
# limits round up to whole vCPUs for the VM. The overhead here covers only the
# host-side components (Kata shim, Cloud Hypervisor, virtiofsd); Microsoft's
# reference table gives 256Mi for a 2Gi pod VM (the chart's default limit).
#
# The chart accepts any RuntimeClass name on-prem except a runc handler without
# allowRunc; a live render fails when the class is missing.
resource "kubectl_manifest" "runtime_class" {
  count = var.create_runtime_class ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = var.runtime_class_name
    }
    handler = var.runtime_class_handler
    overhead = {
      podFixed = {
        cpu    = var.runtime_class_overhead.cpu
        memory = var.runtime_class_overhead.memory
      }
    }
    scheduling = {
      nodeSelector = local.sandbox_node_selector
      tolerations  = [local.sandbox_toleration]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait              = true

  lifecycle {
    # A RuntimeClass whose handler is runc would make "sandboxed" pods share the
    # node kernel while every admission check still passes.
    precondition {
      condition     = !contains(["runc", ""], var.runtime_class_handler)
      error_message = "runtime_class_handler must be the AKS Kata handler, not runc."
    }
  }

  depends_on = [azurerm_kubernetes_cluster_node_pool.sandbox]
}
