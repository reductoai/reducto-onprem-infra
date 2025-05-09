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

# Alertmanager config doc:
# https://prometheus.io/docs/alerting/latest/configuration/#receiver-integration-settings
resource "helm_release" "kube_prometheus_stack" {
  name             = "prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "72.2.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    "${file("values/kube-prometheus-stack.yaml")}",
    <<-EOT
    prometheus:
      prometheusSpec:
        externalLabels:
          cluster: ${var.cluster_name}
          environment: ${var.cluster_name}
    alertmanager:
      config:
        global:
          slack_api_url: ${var.slack_api_url}
        receivers:
        - name: blackhole
        - name: reducto-alerts
          slack_configs:
          - channel: '${var.slack_channel}'
            send_resolved: true
    EOT

  ]

  depends_on = [
    kubectl_manifest.monitoring_ns,
    helm_release.prometheus_crds,
    helm_release.ingress_nginx,
  ]
}