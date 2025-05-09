resource "helm_release" "telegraf" {
  name             = "telegraf"
  repository       = "https://helm.influxdata.com"
  chart            = "telegraf"
  version          = "1.8.55"
  namespace        = "monitoring"
  create_namespace = false

  values = [
    "${file("values/telegraf.yaml")}"
  ]

  depends_on = [
    kubectl_manifest.monitoring_ns,
    kubectl_manifest.telegraf,
  ]
}

resource "kubectl_manifest" "telegraf" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: telegraf
  namespace: monitoring
type: Opaque
data:
  DATABASE_URL: ${base64encode(local.database_url)}
  YAML

  depends_on = [
    kubectl_manifest.monitoring_ns,
  ]
}

resource "kubectl_manifest" "telegraf_sm" {
  yaml_body = <<-YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: telegraf
  namespace: monitoring
spec:
  endpoints:
  - path: /metrics
    port: prometheus-client
  selector:
    matchLabels:
      app.kubernetes.io/instance: telegraf
      app.kubernetes.io/name: telegraf
  YAML

  depends_on = [
    helm_release.prometheus_crds,
    helm_release.kube_prometheus_stack,
  ]
}
