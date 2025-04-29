resource "kubectl_manifest" "cloudflare_api_secret" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Secret
metadata:
  namespace: cert-manager
  name: cloudflare-api-token-secret
type: Opaque
stringData:
  api-token: ${var.cloudflare_api_token}
  YAML

  depends_on = [helm_release.cert_manager]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.15.3"
  namespace        = "cert-manager"
  create_namespace = true

  values = [
    "${file("values/cert-manager.yaml")}"
  ]

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller,
  ]
}


resource "kubectl_manifest" "cluster_issuer_staging" {
  yaml_body = <<-YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: ${var.reducto_helm_repo_username}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
  YAML

  depends_on = [helm_release.cert_manager]
}


resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = <<-YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.reducto_helm_repo_username}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
  YAML

  depends_on = [helm_release.cert_manager]
}
