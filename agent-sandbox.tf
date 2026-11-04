# kubernetes-sigs/agent-sandbox — isolated, stateful, singleton workloads for
# AI agent runtimes. Vendored from the v1.0.7 GitHub release (see
# manifests/agent-sandbox/patch.py) to keep deploys deterministic. Same
# version, bundles and patches as the hosted clusters (reductoai/api
# terragrunt/modules/aws-eks-addons/manifests/agent-sandbox/); the only on-prem
# difference is the system-node label in patch.py.
#
# The two vendored bundles (manifests/agent-sandbox/{core,extensions}.yaml)
# are NOT hand-edited — they are upstream release assets with a fixed,
# declared set of modifications applied by patch.py. That script's PATCHES
# list is the authoritative record of every change made to upstream. To bump
# the version: edit VERSION, ASSET_SHA256 and CONTROLLER_IMAGE_DIGESTS in
# patch.py and run
# `uv run --python 3.12 --with pyyaml python3 manifests/agent-sandbox/patch.py`,
# then `--check` to verify no drift.
#
#   core.yaml       — Sandbox CRD (agents.x-k8s.io/v1beta1), RBAC, the
#     controller metrics Service. Patches strip the leading `Namespace` doc
#     (owned by kubectl_manifest.agent_sandbox_namespace below, so it applies
#     first) and the `agent-sandbox-controller` Deployment (superseded by the
#     identically-named one in extensions.yaml).
#   extensions.yaml — SandboxClaim / SandboxWarmPool / SandboxTemplate CRDs
#     (extensions.agents.x-k8s.io/v1beta1), the sole controller Deployment
#     (run with --extensions), extension RBAC. The patch adds a
#     restricted-PSS securityContext, a writable /tmp emptyDir, two replicas on
#     the system nodes, resources and probes to the controller.
#
# No published Helm chart (assets are these two manifests only). v1.0 CRDs
# serve only v1beta1 and have no conversion webhook, so the controller needs
# no certificate and no cert-manager.

locals {
  # Every namespace the controller may create sandbox pods in, minus its own.
  # The api chart's agentService.sandboxProviders.k8sAgentSandbox.namespace
  # must be one of these (default: reducto-agent-sandbox).
  agent_sandbox_namespaces = setsubtract(var.agent_sandbox_write_namespaces, ["agent-sandbox-system"])

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

# Extensions depend on the core install: the CRDs and core RBAC apply before
# the sole controller Deployment, which lives in extensions.yaml.
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

# Two controller replicas (patch.py) behind leader election; keep one up through
# node rotations so claims never wait for a cold start.
resource "kubectl_manifest" "agent_sandbox_controller_pdb" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "agent-sandbox-controller"
      namespace = "agent-sandbox-system"
    }
    spec = {
      # maxUnavailable, not minAvailable: still evictable if scaled to 1.
      # AlwaysAllow: two CrashLooping replicas must not pin their nodes.
      maxUnavailable             = 1
      unhealthyPodEvictionPolicy = "AlwaysAllow"
      selector                   = { matchLabels = { app = "agent-sandbox-controller" } }
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.agent_sandbox_namespace]
}

# Every sandbox write-namespace must exist before its Role/RoleBinding
# applies. agent-sandbox-system is created above; reducto-agent-sandbox is
# created here via SSA + apply_only (so a stack destroy never deletes it out
# from under anything else namespaced to it), pinned to enforce=restricted —
# sandbox namespaces run untrusted code. Restricted admits the chart's sandbox
# pods (runAsNonRoot, uid/gid 1000, drop ALL, seccomp RuntimeDefault).
resource "kubectl_manifest" "agent_sandbox_write_namespace" {
  for_each = var.enable_agent_sandbox ? local.agent_sandbox_namespaces : toset([])

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

# Zero egress: the sandbox makes no network calls of its own (the agent
# service holds the model keys and moves files in and out through sandboxd), so
# every pod in a sandbox namespace gets no egress at all — no DNS, no
# internet, no VPC, no IMDS, no API server — and no ingress. NetworkPolicies
# add up, so this deny-all is the floor; the api chart adds the one allow
# (ingress to sandboxd 8080/9090 from the agent-service pods only; install with
# k8sAgentSandbox.networkPolicy.createDenyAll=false, since this is the deny-all).
# The agent service checks at start that a deny-all exists and that no policy
# in the namespace has an egress rule, and refuses to start otherwise. Enforced
# by the VPC CNI network policy agent (enableNetworkPolicy in eks.tf); the
# node firewall in gvisor.tf closes the pod -> own-node path that NetworkPolicy
# on EKS does not.
resource "kubectl_manifest" "agent_sandbox_deny_all" {
  for_each = var.enable_agent_sandbox ? local.agent_sandbox_namespaces : toset([])

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "deny-all"
      namespace = each.value
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
    }
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.agent_sandbox_write_namespace]
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
  # The controller only gains pod write once the VAP backstop is in place.
  depends_on = [
    kubectl_manifest.agent_sandbox_core,
    kubectl_manifest.agent_sandbox_namespace,
    kubectl_manifest.agent_sandbox_write_namespace,
    kubectl_manifest.agent_sandbox_controller_vap,
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
