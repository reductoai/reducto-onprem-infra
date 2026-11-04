# gVisor (runsc) isolation runtime for agent-sandbox workloads.
#
# Two pieces, both gated on var.enable_agent_sandbox:
#   - gvisor RuntimeClass (this file).
#   - reducto-sandbox nodes, provisioned per var.sandbox_node_provisioner by
#     either a Karpenter NodePool + EC2NodeClass (karpenter.tf) or an EKS
#     managed node group (eks.tf). Both boot var.sandbox_ami_id, a hardened AMI
#     with runsc baked in, carry the same node-type label + reducto.ai/sandbox
#     taint, register the containerd handler with the NodeConfig below, and
#     (var.enable_sandbox_node_firewall) drop pod -> own-node connections. No
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

  # Node firewall, ported from the hosted `sandbox-node-firewall` unit
  # (reductoai/api terragrunt/modules/aws-eks-addons/templates/
  # al2023-user-data.tftpl, enable_agent_sandbox_node_firewall). NetworkPolicy
  # on EKS does not filter a pod's traffic to its own node's addresses, so the
  # sandbox deny-all alone leaves the host-network ports of the node (kubelet,
  # sshd, kube-proxy, node-exporter, aws-node) reachable. Drop new connections
  # from pod veths (eni*) to the node; replies to kubelet probes are
  # ESTABLISHED and pass. RequiredBy kubelet: after a reboot, kubelet does not
  # start unless the rule is in place.
  sandbox_node_firewall_script = <<-EOT
    #!/bin/bash
    # EKS NetworkPolicy lets a pod reach its own node: drop new connections from
    # pod veths (eni*) to node addresses. Probe replies are ESTABLISHED and pass.
    set -euo pipefail

    cat > /usr/local/bin/sandbox-node-firewall <<'FWSCRIPT'
    #!/bin/bash
    set -euo pipefail
    RULE=(INPUT -i eni+ -m conntrack ! --ctstate ESTABLISHED,RELATED -m comment --comment "reducto-sandbox no pod to own node" -j DROP)
    for ipt in iptables ip6tables; do
      "$${ipt}" -w -t mangle -C "$${RULE[@]}" 2>/dev/null || "$${ipt}" -w -t mangle -I "$${RULE[@]}"
    done
    FWSCRIPT
    chmod 0755 /usr/local/bin/sandbox-node-firewall

    # RequiredBy kubelet: on a reboot, kubelet does not start if the rule fails.
    cat > /etc/systemd/system/sandbox-node-firewall.service <<'UNIT'
    [Unit]
    Description=Drop pod connections to the node's own addresses (reducto-sandbox)
    Before=kubelet.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/bin/sandbox-node-firewall

    [Install]
    WantedBy=multi-user.target
    RequiredBy=kubelet.service
    UNIT

    systemctl daemon-reload
    systemctl enable --now sandbox-node-firewall.service
    logger -t sandbox-node-firewall "installed"
  EOT

  # User data parts for every sandbox node, whichever provisioner created it:
  # the managed node group takes them as cloudinit_pre_nodeadm (eks.tf), the
  # Karpenter EC2NodeClass as the MIME document below (karpenter.tf), which
  # Karpenter merges with its own NodeConfig (cluster endpoint, CA, ...).
  # cloud-init runs the shell part before nodeadm starts kubelet.
  sandbox_user_data_parts = concat(
    var.enable_sandbox_node_firewall ? [{
      content_type = "text/x-shellscript; charset=\"us-ascii\""
      content      = local.sandbox_node_firewall_script
    }] : [],
    [{
      content_type = "application/node.eks.aws"
      content      = local.sandbox_runsc_nodeconfig
    }],
  )

  sandbox_karpenter_user_data = join("", concat(
    ["MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"BOUNDARY\"\n\n"],
    [for part in local.sandbox_user_data_parts : "--BOUNDARY\nContent-Type: ${part.content_type}\n\n${part.content}\n"],
    ["--BOUNDARY--\n"],
  ))
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
