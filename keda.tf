resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.18.3"
  namespace        = "keda"
  create_namespace = true
  timeout          = var.helm_release_timeout

  values = [
    file("values/keda.yaml")
  ]

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller,
  ]
}
