locals {
  reducto_managed_values = yamlencode(merge(
    {
      ingress = {
        host = var.reducto_host
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.reducto.arn
        }
      }
      env = merge(
        {
          DATABASE_URL = local.pooled_database_url
          BUCKET       = aws_s3_bucket.reducto_storage.bucket
        },
        var.enable_elasticache ? {
          REDIS_URL       = local.elasticache_url
          ELASTICACHE_URL = local.elasticache_url
        } : {},
      )
    },
    var.enable_elasticache ? {
      redis = {
        enabled = false
      }
    } : {},
  ))
}

resource "helm_release" "reducto" {
  count            = var.enable_reducto ? 1 : 0
  namespace        = "reducto"
  name             = "reducto"
  create_namespace = true

  repository_username = var.reducto_helm_repo_username
  repository_password = var.reducto_helm_repo_password

  chart   = var.reducto_helm_chart
  version = var.reducto_helm_chart_version
  wait    = false
  timeout = var.helm_release_timeout

  values = concat(
    [
      file("values/reducto.yaml"),
      var.datadog_api_key != "" ? yamlencode(local.otel_env_vars) : "",
      local.reducto_managed_values,
    ],
    [for values_path in var.reducto_extra_values_files : file(values_path)],
  )

  depends_on = [
    module.eks,
    module.rds,
    aws_s3_bucket.reducto_storage,
    aws_iam_role.reducto,
    helm_release.ingress_nginx,
    helm_release.karpenter,
    helm_release.keda,
    helm_release.cert_manager,
    aws_elasticache_replication_group.reducto,
  ]
}
