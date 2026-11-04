# Native ValidatingAdmissionPolicies for the sandbox namespace (see the
# template header for the rules and why VAP, not Kyverno). The controller's own
# backstop (restrict-controller-pod-create) is in controller.tf.

data "kubectl_file_documents" "sandbox_admission" {
  content = templatefile("${path.module}/manifests/admission/sandbox-admission.yaml.tftpl", {
    sandbox_namespace  = var.sandbox_namespace
    runtime_class_name = var.runtime_class_name
    node_label_key     = keys(local.sandbox_node_labels)[0]
    node_label_value   = values(local.sandbox_node_labels)[0]
  })
}

resource "kubectl_manifest" "sandbox_admission" {
  for_each = data.kubectl_file_documents.sandbox_admission.manifests

  yaml_body         = each.value
  server_side_apply = true
  wait              = true

  # The SandboxTemplate rule names the extensions CRD group; apply after it so
  # the API server can type-check the expression against the schema.
  depends_on = [kubectl_manifest.extensions, kubectl_manifest.sandbox_deny_all]
}
