resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.14.1"
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = var.helm_release_timeout

  values = [
    file("values/ingress-nginx-controller.yaml"),
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    module.eks,
    # Keep NAT/routes available while the controller removes its NLB and
    # Kubernetes finalizers during destroy.
    module.vpc,
    helm_release.kube_prometheus_stack,
  ]
}
