# Kyverno admission control. Only the policies relevant to the agent
# sandbox substrate are ported here (see manifests/kyverno/):
#   - require-sandbox-gvisor: enforce `runtimeClassName: gvisor` on every Pod
#     the agent-sandbox controller creates and on every Pod in a sandbox
#     namespace (gated on enable_agent_sandbox too).
#   - require-sandbox-template-unmanaged: reject SandboxTemplates that would
#     let the controller add its own allow-public-egress NetworkPolicy.
#   - restrict-privileged-hostpath: generic Pod Security "baseline" admission
#     backstop (independent of PSS namespace labels/RBAC).
#
# require-sandbox-gvisor is the enforcement mechanism: without it, a
# misconfigured SandboxTemplate could omit runtimeClassName: gvisor and a
# sandbox pod would run un-sandboxed. restrict-privileged-hostpath is a
# general admission backstop (not sandbox-specific) that blocks privileged
# containers and hostPath mounts cluster-wide, closing an easy node-escape
# path. Policies for image-signature verification, HTTPRoute validation, or
# environment-specific database access are intentionally not included here:
# they depend on infrastructure (a signing pipeline, existing routes, a
# particular DB topology) this substrate doesn't assume exists.

locals {
  kyverno_system_node_scheduling = {
    nodeSelector = { "worker-type" = "system" }
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  }
}

resource "helm_release" "kyverno" {
  count = var.enable_kyverno ? 1 : 0

  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_chart_version
  namespace        = "kyverno"
  create_namespace = true
  timeout          = var.helm_release_timeout

  # restrict-privileged-hostpath matches every Pod outside three namespaces
  # and the webhooks fail closed, so Kyverno's admission controller is on the
  # cluster's pod-create path. Run it HA on the system nodes, keep the
  # fail-closed default explicit, and expose metrics for the alert below.
  values = [
    yamlencode(merge(
      {
        features = {
          forceFailurePolicyIgnore = { enabled = false }
        }
        admissionController = merge(local.kyverno_system_node_scheduling, {
          replicas = var.kyverno_admission_replicas
          podDisruptionBudget = {
            enabled      = var.kyverno_admission_replicas > 1
            minAvailable = 1
          }
          serviceMonitor = { enabled = true }
        })
      },
      { for c in ["backgroundController", "cleanupController", "reportsController"] : c => local.kyverno_system_node_scheduling },
    ))
  ]

  depends_on = [module.eks, helm_release.prometheus_crds]
}

resource "kubectl_manifest" "kyverno_prometheus_rules" {
  count     = var.enable_kyverno ? 1 : 0
  yaml_body = file("${path.module}/manifests/kyverno/prometheus-rules.yaml")

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "kyverno_restrict_privileged_hostpath" {
  count             = var.enable_kyverno ? 1 : 0
  yaml_body         = file("${path.module}/manifests/kyverno/restrict-privileged-hostpath.yaml")
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_sandbox_gvisor" {
  count = var.enable_kyverno && var.enable_agent_sandbox ? 1 : 0
  yaml_body = templatefile("${path.module}/manifests/kyverno/require-sandbox-gvisor.yaml.tftpl", {
    sandbox_namespaces = sort(local.pi_sandbox_namespaces)
  })
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_sandbox_template_unmanaged" {
  count             = var.enable_kyverno && var.enable_agent_sandbox ? 1 : 0
  yaml_body         = file("${path.module}/manifests/kyverno/require-sandbox-template-unmanaged.yaml")
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.kyverno]
}
