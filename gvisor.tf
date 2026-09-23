# gVisor (runsc) isolation runtime for agent-sandbox workloads.
#
# Two pieces, both gated on var.enable_agent_sandbox:
#   - gvisor RuntimeClass (this file).
#   - reducto-sandbox nodes, provisioned per var.sandbox_node_provisioner by
#     either a Karpenter NodePool + EC2NodeClass (karpenter.tf) or an EKS
#     managed node group (eks.tf). Both boot var.sandbox_ami_id, a hardened AMI
#     with runsc baked in, carry the same node-type label + reducto.ai/sandbox
#     taint, and register the containerd handler with the NodeConfig below. No
#     node-installer DaemonSet, no boot-time download, no containerd restart —
#     runsc is present before the first pod schedules.
#
# A SandboxTemplate opts in with `runtimeClassName: gvisor`; the RuntimeClass
# scheduling block injects the sandbox-node selector + toleration (matching the
# reducto-sandbox NodePool's node-type label + taint), so untrusted agent pods
# run under runsc on isolated nodes with no per-workload changes.

locals {
  sandbox_karpenter = var.enable_agent_sandbox && var.sandbox_node_provisioner == "karpenter"
  sandbox_mng       = var.enable_agent_sandbox && var.sandbox_node_provisioner == "managed_node_group"

  sandbox_node_label = { "node-type" = "reducto-sandbox" }
  sandbox_node_taint = { key = "reducto.ai/sandbox", value = "true", effect = "NoSchedule" }

  # nodeadm NodeConfig merged into the AMI's containerd config on every
  # sandbox node, whichever provisioner created it.
  sandbox_runsc_nodeconfig = <<-EOT
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
            runtime_type = 'io.containerd.runsc.v1'
          [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc.options]
            BinaryName = '${var.sandbox_runsc_path}'
  EOT
}

resource "kubectl_manifest" "gvisor" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata   = { name = "gvisor" }
    handler    = "runsc"
    # Pod overhead so the scheduler accounts for the runsc sentry+gofer per
    # sandbox pod. Without it, sandbox nodes overcommit memory and OOM under
    # load.
    overhead = {
      podFixed = {
        cpu    = "50m"
        memory = "100Mi"
      }
    }
    scheduling = {
      nodeSelector = local.sandbox_node_label
      tolerations  = [merge(local.sandbox_node_taint, { operator = "Equal" })]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait              = true

  # The RuntimeClass references the sandbox nodes' label/taint.
  depends_on = [kubectl_manifest.karpenter_sandbox_node_pool, module.eks]
}
