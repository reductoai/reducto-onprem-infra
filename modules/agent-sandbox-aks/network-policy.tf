# Sandbox network boundary: ZERO egress. The deny-all itself is in the shared
# namespace.tf; this file holds the AKS-specific reasoning and the Cilium
# egress deny.
#
# The sandbox pods get no egress at all — no Envoy, no DNS. The agent service
# reaches them on 8080/9090 (the chart's ingress policy) and moves every file
# itself; it refuses to start while any policy in the sandbox namespace has an
# egress rule. Terraform owns the deny-all (namespace.tf); install the chart
# with networkPolicy.createDenyAll: false.
#
# Pod -> own node, Azure IMDS (169.254.169.254) and wireserver (168.63.129.16).
# The chart prerequisite is "a host firewall on the sandbox nodes against the
# path from a pod to its own node". On AKS the enforceable control is the
# policy engine itself, not a node firewall:
#   - Azure CNI powered by Cilium enforces a pod's egress policy in eBPF at the
#     pod's own endpoint, for every destination, including the `host` entity
#     (its own node) and remote nodes. Microsoft documents both sides of this:
#     a NetworkPolicy cannot even ALLOW node IPs via ipBlock, and LocalDNS needs
#     an explicit `toEntities: host` allow
#     (https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium).
#     With no egress rule, kubelet (10250), NodePorts, hostPorts, IMDS and
#     wireserver are all denied, the same as the internet.
#   - Kata does not support host networking, and each pod runs behind its own
#     guest kernel, so a sandbox kernel escape lands in the pod VM, not in the
#     node network namespace where these rules live.
#   - NSG rules cannot do this job: pod -> own-node traffic never leaves the
#     host, and with Azure CNI Overlay pod egress is SNATed to the node IP.
#   - AKS "IMDS restriction" (--enable-imds-restriction, preview) adds node
#     iptables rules for every non-hostNetwork pod. It is cluster-wide,
#     preview, and refuses several add-ons, so this module does not turn it on;
#     the install doc lists it as an optional extra layer.
# The provider only sees the policy objects; the install doc's probe pod and
# the agent-service smoke script are the end-to-end checks.

# Cilium only: an egressDeny for every endpoint in the sandbox namespace.
# NetworkPolicies are additive allow-lists, so the deny-all above holds only
# while nobody adds an allow (a stray NetworkPolicy, a CiliumNetworkPolicy, a
# CiliumClusterwideNetworkPolicy, or a SandboxTemplate in Managed mode, whose
# controller policy allows public egress). Cilium evaluates deny rules before
# allow rules, so this keeps egress closed whatever is added later. Replies on
# connections the pod accepted (the agent service on 8080/9090, kubelet
# probes) are not new egress flows and are unaffected. AKS supports
# CiliumClusterwideNetworkPolicy without ACNS (Microsoft Learn, page above).
resource "kubectl_manifest" "sandbox_cilium_egress_deny" {
  count = local.is_cilium && var.create_cilium_egress_deny ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "${var.sandbox_namespace}-egress-deny"
    }
    spec = {
      description = "Reducto agent sandbox: no egress from ${var.sandbox_namespace}, whatever allow policy exists."
      endpointSelector = {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = var.sandbox_namespace
        }
      }
      egressDeny = [
        # Everything: world, cluster, host (own node), remote-node, kube-apiserver.
        { toEntities = ["all"] },
        # Named again so the intent survives an edit of the rule above.
        { toCIDR = ["169.254.169.254/32", "168.63.129.16/32"] },
      ]
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.sandbox_namespace]
}
