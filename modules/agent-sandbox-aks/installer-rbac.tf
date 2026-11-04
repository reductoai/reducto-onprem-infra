# SHARED FILE: copied from modules/agent-sandbox-gke (erica/agent-sandbox-gke
# 6064d60) verbatim, except that the cluster gate is data.azapi_resource.cluster
# instead of data.google_container_cluster.this. Keep in step with the GKE copy
# until both move to a shared modules/agent-sandbox-k8s.
#
# Optional RBAC for the identity that runs `helm install` of the Reducto chart,
# limited to what the chart's agent-sandbox templates need in the sandbox
# namespace (agent-service/AGENTS.md "On-prem": Role, RoleBinding, Secrets in the
# sandbox namespace; get RuntimeClasses; get Secrets for the token lookup). To
# create the agent-service Role, the installer must itself hold every verb that
# Role grants (RBAC escalation check), hence sandboxclaims/pods/networkpolicies.
resource "kubectl_manifest" "installer_role" {
  count = length(var.installer_subjects) > 0 ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "reducto-agent-sandbox-installer"
      namespace = var.sandbox_namespace
    }
    rules = [
      {
        apiGroups = ["rbac.authorization.k8s.io"]
        resources = ["roles", "rolebindings"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = [""]
        resources = ["secrets"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = ["networking.k8s.io"]
        resources = ["networkpolicies"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = ["extensions.agents.x-k8s.io"]
        resources = ["sandboxtemplates", "sandboxwarmpools", "sandboxclaims"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = [""]
        resources = ["pods"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.sandbox_namespace]
}

resource "kubectl_manifest" "installer_role_binding" {
  count = length(var.installer_subjects) > 0 ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "reducto-agent-sandbox-installer"
      namespace = var.sandbox_namespace
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "reducto-agent-sandbox-installer"
    }
    subjects = local.installer_subjects
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.installer_role]
}

resource "kubectl_manifest" "installer_runtimeclass_reader" {
  count = length(var.installer_subjects) > 0 ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata   = { name = "reducto-agent-sandbox-installer-runtimeclass" }
    rules = [{
      apiGroups     = ["node.k8s.io"]
      resources     = ["runtimeclasses"]
      resourceNames = [var.runtime_class_name]
      verbs         = ["get"]
    }]
  })

  server_side_apply = true
  wait              = true
  depends_on        = [data.azapi_resource.cluster]
}

resource "kubectl_manifest" "installer_runtimeclass_reader_binding" {
  count = length(var.installer_subjects) > 0 ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "reducto-agent-sandbox-installer-runtimeclass" }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "reducto-agent-sandbox-installer-runtimeclass"
    }
    subjects = local.installer_subjects
  })

  server_side_apply = true
  wait              = true
  depends_on        = [kubectl_manifest.installer_runtimeclass_reader]
}

locals {
  installer_subjects = [
    for s in var.installer_subjects : merge(
      { kind = s.kind, name = s.name },
      s.kind == "ServiceAccount" ? tomap({ namespace = s.namespace }) : tomap({ apiGroup = "rbac.authorization.k8s.io" }),
    )
  ]
}
