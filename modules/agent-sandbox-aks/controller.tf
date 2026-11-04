# SHARED FILE: copied from modules/agent-sandbox-gke (erica/agent-sandbox-gke
# 6064d60) verbatim, except that the cluster gate is data.azapi_resource.cluster
# instead of data.google_container_cluster.this. Keep in step with the GKE copy
# until both move to a shared modules/agent-sandbox-k8s.
#
# kubernetes-sigs/agent-sandbox controller + CRDs, the same v1.0.7 release and
# the same patches as hosted (reductoai/api terragrunt/modules/aws-eks-addons/
# agent-sandbox.tf), with the --extensions controller (SandboxTemplate,
# SandboxWarmPool, SandboxClaim; agents.x-k8s.io/v1beta1 and
# extensions.agents.x-k8s.io/v1beta1). The Reducto chart needs v1.0.6 or later.
#
# The bundles in manifests/agent-sandbox/ are upstream release assets with the
# declared modifications of patch.py applied (sha256-pinned assets, controller
# image pinned by digest). Do not hand-edit them: edit patch.py and run
# `uv run --with pyyaml python3 manifests/agent-sandbox/patch.py` (then
# `--check`). The only difference from the hosted copy is that the controller
# is not pinned to an EKS system pool (see patch.py).
#
# patch.py also narrows both controller ClusterRoles to read-only on pods, PVCs,
# services, network policies, and leases; the Role below grants the write verbs
# back only in the sandbox namespace (and leases only in agent-sandbox-system).
# The ValidatingAdmissionPolicy restrict-controller-pod-create is the
# independent backstop: the controller SA can create or modify pods only in the
# sandbox namespace, so a harvested controller token cannot plant a pod in
# kube-system or any other privileged namespace.

locals {
  controller_namespace = "agent-sandbox-system"

  pss_restricted_labels = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = var.pss_version
    "pod-security.kubernetes.io/audit"           = "restricted"
    "pod-security.kubernetes.io/audit-version"   = var.pss_version
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/warn-version"    = var.pss_version
  }
}

# Applied on its own first, so the namespaced docs of the bundles never race
# ahead of it. restricted PSS: patch.py gives the controller a restricted-
# compliant securityContext.
resource "kubectl_manifest" "controller_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = local.controller_namespace
      labels = local.pss_restricted_labels
    }
  })

  server_side_apply = true
  wait              = true

  # Gate every Kubernetes object on the cluster postconditions (main.tf).
  depends_on = [data.azapi_resource.cluster]
}

# GKE admits pods with the system-cluster-critical / system-node-critical
# PriorityClass outside kube-system only when the namespace has a ResourceQuota
# scoped to that class (a GKE-configured ResourceQuota admission limit). The
# controller runs at system-cluster-critical (patch.py) so ordinary workloads
# cannot preempt it.
# AKS does not document that limit; the quota only allows these pods, so it is
# harmless there and keeps this file identical to the GKE copy.
resource "kubectl_manifest" "controller_critical_pods_quota" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ResourceQuota"
    metadata = {
      name      = "critical-pods"
      namespace = local.controller_namespace
    }
    spec = {
      # 2 replicas + 1 surge pod during a rollout, with headroom.
      hard = { pods = "4" }
      scopeSelector = {
        matchExpressions = [{
          operator  = "In"
          scopeName = "PriorityClass"
          values    = ["system-cluster-critical"]
        }]
      }
    }
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.controller_namespace]
}

data "kubectl_file_documents" "core" {
  content = file("${path.module}/manifests/agent-sandbox/core.yaml")
}

resource "kubectl_manifest" "core" {
  for_each = data.kubectl_file_documents.core.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  depends_on = [kubectl_manifest.controller_namespace]
}

data "kubectl_file_documents" "extensions" {
  content = file("${path.module}/manifests/agent-sandbox/extensions.yaml")
}

resource "kubectl_manifest" "extensions" {
  for_each = data.kubectl_file_documents.extensions.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  depends_on = [
    kubectl_manifest.core,
    kubectl_manifest.controller_critical_pods_quota,
  ]
}

# Two replicas (patch.py) behind leader election; keep one up through node
# upgrades so claims never wait for a cold start.
resource "kubectl_manifest" "controller_pdb" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "agent-sandbox-controller"
      namespace = local.controller_namespace
    }
    spec = {
      maxUnavailable             = 1
      unhealthyPodEvictionPolicy = "AlwaysAllow"
      selector                   = { matchLabels = { app = "agent-sandbox-controller" } }
    }
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.controller_namespace]
}

# Namespaced replacement for the cluster-wide write verbs patch.py strips.
# agent-sandbox-system gets only its leader-election lease; the sandbox
# namespace gets workload write and no lease.
resource "kubectl_manifest" "controller_workloads_role" {
  for_each = toset([local.controller_namespace, var.sandbox_namespace])

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "agent-sandbox-controller-workloads"
      namespace = each.value
    }
    rules = each.value == local.controller_namespace ? [
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
  # The controller gains pod write only once the VAP backstops (its own, and
  # the sandbox pod isolation rules) and the deny-all are in place.
  depends_on = [
    kubectl_manifest.core,
    kubectl_manifest.controller_namespace,
    kubectl_manifest.sandbox_namespace,
    kubectl_manifest.sandbox_deny_all,
    kubectl_manifest.controller_vap,
    kubectl_manifest.sandbox_admission,
  ]
}

resource "kubectl_manifest" "controller_workloads_binding" {
  for_each = toset([local.controller_namespace, var.sandbox_namespace])

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
      namespace = local.controller_namespace
    }]
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.controller_workloads_role]
}

# Same template as hosted. Allowlist = the sandbox namespace only (the
# controller creates no pods in agent-sandbox-system). CEL list literal with
# single quotes so it nests inside the double-quoted YAML expression.
data "kubectl_file_documents" "controller_vap" {
  content = templatefile(
    "${path.module}/manifests/agent-sandbox/restrict-controller-pod-create.yaml.tftpl",
    { allowlist = "['${var.sandbox_namespace}']" },
  )
}

resource "kubectl_manifest" "controller_vap" {
  for_each = data.kubectl_file_documents.controller_vap.manifests

  yaml_body         = each.value
  server_side_apply = true
  wait              = true

  depends_on = [data.azapi_resource.cluster]
}
