resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.2"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    templatefile("${path.module}/values/ingress-nginx-controller.yaml", {
      reducto_nlb_cert_arn = var.reducto_nlb_cert_arn
    })
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    module.eks
  ]
}