# kubernetes-sigs/agent-sandbox controller (with --extensions) and its CRDs
# (agents.x-k8s.io/v1beta1, extensions.agents.x-k8s.io/v1beta1).
#
# manifests/agent-sandbox/{core,extensions}.yaml, patch.py and
# restrict-controller-pod-create.yaml.tftpl are byte-identical copies of
# reductoai/api terragrunt/modules/aws-eks-addons/manifests/agent-sandbox/ at
# api@6a8db2b36a (v1.0.7, the version hosted runs; the chart needs v1.0.6+).
# Do not hand-edit them: bump in api with patch.py, then copy the four files
# here, so on-prem and hosted run the same controller and the same RBAC
# narrowing. `diff -r` against api is the drift check.
#
# What patch.py did upstream (see its PATCHES list): drops the Namespace doc
# (created below so it applies first) and the core Deployment (superseded by
# the --extensions one); adds a restricted-PSS securityContext, /tmp emptyDir,
# HA (2 replicas, leader election, spread), resources; narrows both
# ClusterRoles to read-only for pods/pvc/services/networkpolicies/leases
# cluster-wide. Write access comes back only through the namespaced Role
# below. v1.0 CRDs have no conversion webhook, so no cert-manager dependency.
#
# The ONE AKS-specific change is applied here, not in the vendored file: the
# hosted controller pins nodeSelector node-type=system (an EKS label). It is
# replaced with var.controller_node_selector / var.controller_tolerations (AKS
# system-mode pools by default), and replicas with var.controller_replicas.

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

locals {
  extensions_manifests = data.kubectl_file_documents.extensions.manifests

  # one() fails the plan if upstream renames or duplicates the Deployment, so
  # the override can never silently miss.
  controller_key = one([
    for k, v in local.extensions_manifests : k
    if yamldecode(v).kind == "Deployment" && yamldecode(v).metadata.name == "agent-sandbox-controller"
  ])
  controller_doc = yamldecode(local.extensions_manifests[local.controller_key])

  controller_tolerations = [
    for t in var.controller_tolerations : { for k, v in t : k => v if v != null }
  ]

  controller_deployment = merge(local.controller_doc, {
    spec = merge(local.controller_doc.spec, {
      replicas = var.controller_replicas
      template = merge(local.controller_doc.spec.template, {
        spec = merge(local.controller_doc.spec.template.spec, {
          nodeSelector = var.controller_node_selector
          tolerations  = local.controller_tolerations
        })
      })
    })
  })

  extensions_bodies = merge(local.extensions_manifests, {
    (local.controller_key) = yamlencode(local.controller_deployment)
  })
}

resource "kubectl_manifest" "extensions" {
  for_each = local.extensions_bodies

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  depends_on = [kubectl_manifest.core]
}

# Keep one controller replica up through node-pool upgrades so claims never
# wait for a cold start. Same object as hosted.
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

  depends_on = [kubectl_manifest.controller_namespace]
}

# The sandbox namespace. apply_only: a destroy of this module never deletes
# the namespace (and the chart objects in it) out from under a live release.
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
}

# Namespaced replacement for the cluster-wide write that patch.py strips from
# both controller ClusterRoles. The controller still watches cluster-wide, but
# can only mutate pods/pvc/services/networkpolicies in the sandbox namespace,
# and only the leader-election lease in its own namespace. This is what lets
# the controller create pods in the sandbox namespace (a chart prerequisite).
resource "kubectl_manifest" "controller_workloads_role" {
  for_each = toset(local.write_namespaces)

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

  # The controller gains pod write only after the VAP backstop, the deny-all,
  # and the sandbox-pod admission policies are in place, so it can never create
  # a sandbox pod into an unguarded namespace.
  depends_on = [
    kubectl_manifest.core,
    kubectl_manifest.controller_namespace,
    kubectl_manifest.sandbox_namespace,
    kubectl_manifest.controller_vap,
    kubectl_manifest.sandbox_deny_all,
    kubectl_manifest.admission,
  ]
}

resource "kubectl_manifest" "controller_workloads_binding" {
  for_each = toset(local.write_namespaces)

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

# Fail-closed ValidatingAdmissionPolicy (vendored from hosted): the controller
# ServiceAccount may create/update pods ONLY in the sandbox namespace. Native
# to the API server, so it also covers kube-system, where a webhook engine is
# usually excluded. The allowlist renders from the same namespace as the Role.
data "kubectl_file_documents" "controller_vap" {
  content = templatefile(
    "${path.module}/manifests/agent-sandbox/restrict-controller-pod-create.yaml.tftpl",
    { allowlist = format("['%s']", var.sandbox_namespace) },
  )
}

resource "kubectl_manifest" "controller_vap" {
  for_each = data.kubectl_file_documents.controller_vap.manifests

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}
