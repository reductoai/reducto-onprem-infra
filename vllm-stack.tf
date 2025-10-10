resource "kubernetes_namespace" "vllm_stack" {
  count = var.enable_vllm_stack ? 1 : 0

  metadata {
    name = "vllm-stack"
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "hf_token" {
  count = var.enable_vllm_stack ? 1 : 0
  metadata {
    name      = "hf-token-secret"
    namespace = kubernetes_namespace.vllm_stack[0].metadata[0].name
  }
  type = "Opaque"
  data = { token = var.vllm_stack_hf_token }
}

resource "helm_release" "vllm_stack" {
  count = var.enable_vllm_stack ? 1 : 0

  name             = "vllm-stack"
  repository       = "https://vllm-project.github.io/production-stack"
  chart            = "vllm-stack"
  version          = "0.1.7"
  namespace        = kubernetes_namespace.vllm_stack[0].metadata[0].name
  create_namespace = false

  values = [file("values/vllm-stack.yaml")]

  timeout         = 900
  cleanup_on_fail = true
  force_update    = true
  recreate_pods   = true
  wait            = true
  wait_for_jobs   = true

  depends_on = [
    module.eks,
    kubernetes_secret.hf_token,
  ]
}
