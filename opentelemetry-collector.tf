locals {
  otel_collector_extra_env = concat(
    var.enable_otel_collector && var.otel_auth_token != "" ? [
      {
        name = "OTEL_AUTH_TOKEN"
        valueFrom = {
          secretKeyRef = {
            name = "otel-auth-token"
            key  = "OTEL_AUTH_TOKEN"
          }
        }
      }
    ] : [],
    var.enable_otel_collector && var.otel_datadog_api_key != "" ? [
      {
        name = "OTEL_DATADOG_API_KEY"
        valueFrom = {
          secretKeyRef = {
            name = "otel-datadog-api"
            key  = "OTEL_DATADOG_API_KEY"
          }
        }
      }
    ] : []
  )
}

resource "kubectl_manifest" "otel_auth_secret" {
  count     = var.enable_otel_collector && var.otel_auth_token != "" ? 1 : 0
  yaml_body = <<-YAML
  apiVersion: v1
  kind: Secret
  metadata:
    name: otel-auth-token
    namespace: monitoring
  type: Opaque
  stringData:
    OTEL_AUTH_TOKEN: ${var.otel_auth_token}
  YAML

  depends_on = [
    kubectl_manifest.monitoring_ns,
  ]
}

resource "kubectl_manifest" "otel_datadog_secret" {
  count     = var.enable_otel_collector && var.otel_datadog_api_key != "" ? 1 : 0
  yaml_body = <<-YAML
  apiVersion: v1
  kind: Secret
  metadata:
    name: otel-datadog-api
    namespace: monitoring
  type: Opaque
  stringData:
    OTEL_DATADOG_API_KEY: ${var.otel_datadog_api_key}
  YAML

  depends_on = [
    kubectl_manifest.monitoring_ns,
  ]
}

resource "helm_release" "opentelemetry_collector" {
  count = var.enable_otel_collector ? 1 : 0

  name             = "opentelemetry-collector"
  namespace        = "monitoring"
  create_namespace = false
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = "0.138.0"
  wait             = false

  values = concat(
    [
      file("values/opentelemetry-collector.yaml"),
    ],
    length(local.otel_collector_extra_env) > 0 ? [
      yamlencode({
        extraEnvs = local.otel_collector_extra_env
      })
    ] : []
  )
  depends_on = [
    helm_release.datadog,
    kubectl_manifest.otel_auth_secret,
    kubectl_manifest.otel_datadog_secret,
  ]
}
