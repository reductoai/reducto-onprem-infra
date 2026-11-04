# Admission guards for the sandbox, as native ValidatingAdmissionPolicies.
#
# Hosted enforces the same rules with Kyverno (require-sandbox-gvisor,
# require-sandbox-template-unmanaged). On AKS this module uses the API
# server's own CEL admission instead:
#   - no extra in-cluster dependency: no webhook Deployment to install, keep
#     highly available, upgrade, and alert on; a down webhook cannot fail open
#     or block the cluster, because there is none;
#   - it covers every namespace (Kyverno's chart excludes kube-system and
#     friends by default), which is why hosted already uses a VAP for the
#     controller pod-create backstop;
#   - GA in Kubernetes 1.30 (the module requires 1.30+); every rule here is a
#     field check that CEL expresses directly, so Kyverno adds nothing.
# All policies fail closed (failurePolicy Fail) and write audit annotations.
# Every expression guards optional fields with has(), so none can error.

locals {
  vap_api = "admissionregistration.k8s.io/v1"

  sandbox_namespace_selector = {
    matchExpressions = [{
      key      = "kubernetes.io/metadata.name"
      operator = "In"
      values   = [var.sandbox_namespace]
    }]
  }

  admission_docs = {
    # Sandbox pods must run on the Kata runtime and carry no ServiceAccount
    # token. The node taint only steers scheduling; runtimeClassName is what
    # selects the pod VM, and a pod without it would run on runc with the node
    # kernel. Both fields are immutable, so CREATE is enough.
    "policy-sandbox-pod" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "reducto-sandbox-pod-isolation" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE"]
            resources   = ["pods"]
          }]
        }
        validations = [
          {
            expression = "has(object.spec.runtimeClassName) && object.spec.runtimeClassName == '${local.runtime_class_name}'"
            message    = "Sandbox pods must set runtimeClassName: ${local.runtime_class_name} (AKS Pod Sandboxing / Kata VM isolation for untrusted agent code)."
          },
          {
            expression = "has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false"
            message    = "Sandbox pods must set automountServiceAccountToken: false (no Kubernetes API credential inside untrusted agent code)."
          },
        ]
      }
    }
    # Two bindings, either one is enough (a single binding ANDs its selectors):
    # every pod in the sandbox namespace, labeled or not, so a holder of the
    # controller token cannot create a runc pod by omitting the label ...
    "binding-sandbox-pod-namespace" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "reducto-sandbox-pod-isolation-namespace" }
      spec = {
        policyName        = "reducto-sandbox-pod-isolation"
        validationActions = ["Deny", "Audit"]
        matchResources    = { namespaceSelector = local.sandbox_namespace_selector }
      }
    }
    # ... and every pod the agent-sandbox controller labels, in any namespace.
    "binding-sandbox-pod-label" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "reducto-sandbox-pod-isolation-label" }
      spec = {
        policyName        = "reducto-sandbox-pod-isolation"
        validationActions = ["Deny", "Audit"]
        matchResources = {
          objectSelector = {
            matchExpressions = [{
              key      = "agents.x-k8s.io/sandbox-name-hash"
              operator = "Exists"
            }]
          }
        }
      }
    }

    # SandboxTemplate.spec.networkPolicyManagement defaults to Managed; then the
    # controller creates its own NetworkPolicy that allows public egress, which
    # adds to (and so defeats) the deny-all. The CRD applies its default before
    # admission, so an omitted field is rejected too. The chart sets Unmanaged.
    "policy-template-unmanaged" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "reducto-sandbox-template-unmanaged" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["extensions.agents.x-k8s.io"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["sandboxtemplates"]
          }]
        }
        validations = [{
          expression = "has(object.spec.networkPolicyManagement) && object.spec.networkPolicyManagement == 'Unmanaged'"
          message    = "SandboxTemplates must set spec.networkPolicyManagement: Unmanaged. Sandbox egress is denied by the namespace deny-all; the controller's Managed policy allows public egress."
        }]
      }
    }
    "binding-template-unmanaged" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "reducto-sandbox-template-unmanaged" }
      spec = {
        policyName        = "reducto-sandbox-template-unmanaged"
        validationActions = ["Deny", "Audit"]
      }
    }

    # Keeps the zero-egress invariant that the agent service checks only at its
    # start: no NetworkPolicy in the sandbox namespace may carry an egress rule.
    # The chart's ingress policy has none; the deny-all has none.
    "policy-networkpolicy-no-egress" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicy"
      metadata   = { name = "reducto-sandbox-networkpolicy-no-egress" }
      spec = {
        failurePolicy = "Fail"
        matchConstraints = {
          resourceRules = [{
            apiGroups   = ["networking.k8s.io"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["networkpolicies"]
          }]
        }
        validations = [{
          expression = "!has(object.spec.egress) || size(object.spec.egress) == 0"
          message    = "NetworkPolicies in the sandbox namespace must not have egress rules: the sandboxes have no egress at all."
        }]
      }
    }
    "binding-networkpolicy-no-egress" = {
      apiVersion = local.vap_api
      kind       = "ValidatingAdmissionPolicyBinding"
      metadata   = { name = "reducto-sandbox-networkpolicy-no-egress" }
      spec = {
        policyName        = "reducto-sandbox-networkpolicy-no-egress"
        validationActions = ["Deny", "Audit"]
        matchResources    = { namespaceSelector = local.sandbox_namespace_selector }
      }
    }
  }
}

# A binding may precede its policy and a policy may name a CRD that is not
# installed yet, so these apply in any order and need no dependency on the
# controller bundle.
resource "kubectl_manifest" "admission" {
  for_each = { for name, doc in local.admission_docs : name => yamlencode(doc) }

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}
