# Kyverno admission control. Only the two policies relevant to the agent
# sandbox substrate are ported here (see manifests/kyverno/):
#   - require-sandbox-gvisor: enforce `runtimeClassName: gvisor` on every Pod
#     the agent-sandbox controller creates (gated on enable_agent_sandbox too).
#   - restrict-privileged-hostpath: generic Pod Security "baseline" admission
#     backstop (independent of PSS namespace labels/RBAC).
#
# Ported verbatim from the same policies already proven on Reducto's staging-2
# cluster. Fleet-specific policies (image-signature verification against
# Reducto's private ECR, HTTPRoute policies, staging-DB access restriction)
# are intentionally NOT ported — out of scope for the sandbox substrate.

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
