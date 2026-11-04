# SHARED FILE: copied from modules/agent-sandbox-gke (erica/agent-sandbox-gke
# 6064d60) verbatim, except that the cluster gate is data.azapi_resource.cluster
# instead of data.google_container_cluster.this. Keep in step with the GKE copy
# until both move to a shared modules/agent-sandbox-k8s.
#
# The sandbox namespace and its zero-egress deny-all.
#
# Split of ownership (same as hosted, 2026-10-19):
#   - Terraform (here): the namespace, its PSS labels, and `deny-all` — every
#     pod, Ingress + Egress, no rules. No DNS, no metadata server, nothing.
#   - The Reducto chart: the only allow (`<release>-agent-sandbox-ingress`:
#     ingress to sandboxd 8080/9090 from the agent-service pods), the agent-
#     service Role/RoleBinding, SandboxTemplate/SandboxWarmPool, and the token
#     digest Secret. Install the chart with
#     agentService.sandboxProviders.k8sAgentSandbox.networkPolicy.createDenyAll=false.
#
# The agent service refuses to start unless a policy here denies all egress of
# every pod and no policy has an egress rule; the admission policy
# sandbox-namespace-no-egress (admission.tf) refuses such a policy up front.

# apply_only: a `terraform destroy` of this module leaves the namespace (and
# whatever the chart put in it) in place.
resource "kubectl_manifest" "sandbox_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = var.sandbox_namespace
      labels = local.pss_restricted_labels
    }
  })

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  depends_on = [data.azapi_resource.cluster]
}

resource "kubectl_manifest" "sandbox_deny_all" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "deny-all"
      namespace = var.sandbox_namespace
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
    }
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.sandbox_namespace]
}
