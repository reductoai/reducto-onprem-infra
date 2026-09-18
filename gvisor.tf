# gVisor (runsc) isolation runtime for agent-sandbox workloads.
#
# Two pieces, both gated on var.enable_agent_sandbox:
#   - gvisor RuntimeClass (this file).
#   - reducto-sandbox Karpenter NodePool + EC2NodeClass (karpenter.tf): tainted
#     nodes whose userData installs runsc + registers the runtime handler at
#     boot. No node-installer DaemonSet, no containerd restart, no bootstrap
#     race — runsc is present before the first pod schedules.
#
# A SandboxTemplate opts in with `runtimeClassName: gvisor`; the RuntimeClass
# scheduling block injects the sandbox-node selector + toleration (matching the
# reducto-sandbox NodePool's node-type label + taint), so untrusted agent pods
# run under runsc on isolated nodes with no per-workload changes.

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
      nodeSelector = { "node-type" = "reducto-sandbox" }
      tolerations = [{
        key      = "reducto.ai/sandbox"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait              = true

  # The RuntimeClass references the reducto-sandbox NodePool's node label/taint.
  depends_on = [kubectl_manifest.karpenter_sandbox_node_pool]
}
