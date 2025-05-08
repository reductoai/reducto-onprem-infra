resource "kubectl_manifest" "monitoring_ns" {
  yaml_body = <<-YAML
  apiVersion: v1
  kind: Namespace
  metadata:
    labels:
      name: monitoring
    name: monitoring
  spec:
    finalizers:
    - kubernetes
  YAML
}

resource "helm_release" "prometheus_crds" {
  name             = "prometheus-operator-crds"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-operator-crds"
  version          = "20.0.0"
  namespace        = "monitoring"
  create_namespace = false

  depends_on = [
    kubectl_manifest.monitoring_ns,
  ]
}