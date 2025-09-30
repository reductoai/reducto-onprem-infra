resource "helm_release" "reducto" {
  count            = var.create_reducto_helm_release ? 1 : 0
  namespace        = "reducto"
  name             = "reducto"
  create_namespace = true

  repository_username = var.reducto_helm_repo_username
  repository_password = var.reducto_helm_repo_password

  chart   = var.reducto_helm_chart
  version = var.reducto_helm_chart_version
  wait    = false

  values = [
    "${file("values/reducto.yaml")}",
    <<-EOT
    ingress:
      host: ${var.reducto_host}
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.reducto.arn}
    env:
      DATABASE_URL: ${local.pooled_database_url}
      BUCKET: ${aws_s3_bucket.reducto_storage.bucket}
    EOT
  ]

  depends_on = [
    module.eks,
    module.rds,
    aws_s3_bucket.reducto_storage,
    aws_iam_role.reducto,
    helm_release.ingress_nginx,
    helm_release.karpenter,
    helm_release.keda,
    helm_release.cert_manager,
  ]
}