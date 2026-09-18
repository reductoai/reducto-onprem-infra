# Kyverno admission control. Only the two policies relevant to the agent
# sandbox substrate are ported here (see manifests/kyverno/):
#   - require-sandbox-gvisor: enforce `runtimeClassName: gvisor` on every Pod
#     the agent-sandbox controller creates (gated on enable_agent_sandbox too).
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

resource "helm_release" "kyverno" {
  count = var.enable_kyverno ? 1 : 0

  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_chart_version
  namespace        = "kyverno"
  create_namespace = true
  timeout          = var.helm_release_timeout

  depends_on = [module.eks]
}

resource "kubectl_manifest" "kyverno_restrict_privileged_hostpath" {
  count             = var.enable_kyverno ? 1 : 0
  yaml_body         = file("${path.module}/manifests/kyverno/restrict-privileged-hostpath.yaml")
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_sandbox_gvisor" {
  count             = var.enable_kyverno && var.enable_agent_sandbox ? 1 : 0
  yaml_body         = file("${path.module}/manifests/kyverno/require-sandbox-gvisor.yaml")
  server_side_apply = true
  wait              = true

  depends_on = [helm_release.kyverno]
}
