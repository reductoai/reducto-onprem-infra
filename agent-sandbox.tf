# kubernetes-sigs/agent-sandbox — isolated, stateful, singleton workloads for
# AI agent runtimes. Vendored from the v0.5.3 GitHub release (see
# manifests/agent-sandbox/patch.py) to keep deploys deterministic. Ported from
# the same substrate already proven on Reducto's staging-2 cluster.
#
# The two vendored bundles (manifests/agent-sandbox/{core,extensions}.yaml)
# are NOT hand-edited — they are upstream release assets with a fixed,
# declared set of modifications applied by patch.py. That script's PATCHES
# list is the authoritative record of every change made to upstream. To bump
# the version: edit VERSION in patch.py and run
# `uv run --python 3.12 --with pyyaml python3 manifests/agent-sandbox/patch.py`,
# then `--check` to verify no drift.
#
#   core.yaml       — Sandbox CRD, RBAC, the two Services (controller +
#     webhook), conversion webhook. Patches strip the leading `Namespace` doc
#     (owned by kubectl_manifest.agent_sandbox_namespace below, so it applies
#     first) and the `agent-sandbox-controller` Deployment (superseded by the
#     identically-named one in extensions.yaml).
#   extensions.yaml — SandboxClaim / SandboxWarmPool / SandboxTemplate CRDs,
#     the sole controller Deployment, extension RBAC. The patch adds a
#     restricted-PSS securityContext + writable /tmp emptyDir to the
#     controller.
#
# No published Helm chart (assets are these two manifests only). No
# cert-manager dependency: the controller self-injects the conversion webhook
# caBundle.

locals {
  agent_sandbox_pss_labels = {
    "pod-security.kubernetes.io/enforce" = "restricted"
    "pod-security.kubernetes.io/audit"   = "restricted"
    "pod-security.kubernetes.io/warn"    = "restricted"
  }
}

# Namespace applied on its own first, so the namespaced docs in core.yaml
# (RBAC, Service, Deployment) never race ahead of the namespace they target.
resource "kubectl_manifest" "agent_sandbox_namespace" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = "agent-sandbox-system"
      labels = local.agent_sandbox_pss_labels
    }
  })

  server_side_apply = true
  wait              = true
}

data "kubectl_file_documents" "agent_sandbox_core" {
  count   = var.enable_agent_sandbox ? 1 : 0
  content = file("${path.module}/manifests/agent-sandbox/core.yaml")
}

resource "kubectl_manifest" "agent_sandbox_core" {
  for_each = var.enable_agent_sandbox ? data.kubectl_file_documents.agent_sandbox_core[0].manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  depends_on = [kubectl_manifest.agent_sandbox_namespace]
}

# Extensions depend on the core install: their controller and the conversion
# webhook for the extension CRDs are served by the core controller.
data "kubectl_file_documents" "agent_sandbox_ext" {
  count   = var.enable_agent_sandbox ? 1 : 0
  content = file("${path.module}/manifests/agent-sandbox/extensions.yaml")
}

resource "kubectl_manifest" "agent_sandbox_ext" {
  for_each = var.enable_agent_sandbox ? data.kubectl_file_documents.agent_sandbox_ext[0].manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  depends_on = [kubectl_manifest.agent_sandbox_core]
}

# Every sandbox write-namespace must exist before its Role/RoleBinding
# applies. agent-sandbox-system is created above; reducto-pi-sandbox is
# created here via SSA + apply_only (so a stack destroy never deletes it out
# from under anything else namespaced to it), pinned to enforce=restricted —
# sandbox namespaces run untrusted code.
resource "kubectl_manifest" "agent_sandbox_write_namespace" {
  for_each = var.enable_agent_sandbox ? toset(setsubtract(var.agent_sandbox_write_namespaces, ["agent-sandbox-system"])) : toset([])

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = each.value
      labels = local.agent_sandbox_pss_labels
    }
  })

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true
}

# Namespaced replacement for the cluster-wide WRITE (create/delete/patch/
# update) that patch.py (SetRuleVerbs) strips from both the controller
# ClusterRole (pods/pvc/services, leases) and the -extensions ClusterRole
# (pods/networkpolicies, leases). The controller still watches those
# resources cluster-wide (get/list/watch stays on the ClusterRoles), but can
# only mutate them in the sandbox namespaces.
resource "kubectl_manifest" "agent_sandbox_controller_workloads_role" {
  for_each = var.enable_agent_sandbox ? toset(var.agent_sandbox_write_namespaces) : toset([])

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "agent-sandbox-controller-workloads"
      namespace = each.value
    }
    # agent-sandbox-system (the controller's OWN namespace) gets only the
    # leader-election lease, never workload write. Sandbox namespaces get
    # workload write and no lease.
    rules = each.value == "agent-sandbox-system" ? [
      {
        apiGroups = ["coordination.k8s.io"]
        resources = ["leases"]
        verbs     = ["create", "delete", "patch", "update"]
      },
      ] : [
      {
        apiGroups = [""]
        resources = ["persistentvolumeclaims", "pods", "services"]
        verbs     = ["create", "delete", "patch", "update"]
      },
      {
        apiGroups = ["networking.k8s.io"]
        resources = ["networkpolicies"]
        verbs     = ["create", "delete", "patch", "update"]
      },
    ]
  })

  server_side_apply = true
  wait              = true
  depends_on = [
    kubectl_manifest.agent_sandbox_core,
    kubectl_manifest.agent_sandbox_namespace,
    kubectl_manifest.agent_sandbox_write_namespace,
  ]
}

resource "kubectl_manifest" "agent_sandbox_controller_workloads_binding" {
  for_each = var.enable_agent_sandbox ? toset(var.agent_sandbox_write_namespaces) : toset([])

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "agent-sandbox-controller-workloads"
      namespace = each.value
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "agent-sandbox-controller-workloads"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = "agent-sandbox-controller"
      namespace = "agent-sandbox-system"
    }]
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.agent_sandbox_controller_workloads_role]
}

# Fail-closed ValidatingAdmissionPolicy: denies the controller SA creating
# pods outside the sandbox write-namespaces. API-server-native (not Kyverno)
# so it covers kube-system/kube-public/kube-node-lease, which Kyverno's chart
# defaults exclude from both the webhook and resourceFilters. Allowlist
# renders from the same var as the Role above, so the two never drift.
data "kubectl_file_documents" "agent_sandbox_controller_vap" {
  count = var.enable_agent_sandbox ? 1 : 0
  content = templatefile(
    "${path.module}/manifests/agent-sandbox/restrict-controller-pod-create.yaml.tftpl",
    { allowlist = format("[%s]", join(", ", [for ns in var.agent_sandbox_write_namespaces : "'${ns}'" if ns != "agent-sandbox-system"])) },
  )
}

resource "kubectl_manifest" "agent_sandbox_controller_vap" {
  for_each = var.enable_agent_sandbox ? data.kubectl_file_documents.agent_sandbox_controller_vap[0].manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}
