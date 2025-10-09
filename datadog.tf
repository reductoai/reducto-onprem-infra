resource "kubectl_manifest" "datadog_secret" {
    count = var.datadog_api_key != "" ? 1 : 0
    yaml_body = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: datadog-secret
      namespace: monitoring
    type: Opaque
    stringData:
      api-key: ${var.datadog_api_key}
    YAML

    depends_on = [
        kubectl_manifest.monitoring_ns,
    ]
}

resource "helm_release" "datadog" {
  count = var.datadog_api_key != "" ? 1 : 0
  name             = "datadog"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  version          = "3.133.0"
  namespace        = "monitoring"
  create_namespace = false
  wait             = false

  values = [
    "${file("values/datadog.yaml")}",
    <<-EOT
    datadog:
      site: ${var.datadog_site}
    EOT
  ]

  depends_on = [
    kubectl_manifest.datadog_secret,
  ]
}


locals {
  otel_env_vars = { 
    env = {
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://datadog.monitoring.svc.cluster.local:4318"
    }
  }
}
