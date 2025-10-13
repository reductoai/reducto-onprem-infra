resource "kubernetes_secret" "hf_token" {
  count = var.enable_vllm_stack ? 1 : 0
  metadata {
    name      = "hf-token-secret"
    namespace = "reducto"
  }
  type = "Opaque"
  data = { token = var.vllm_stack_hf_token }

  depends_on = [helm_release.reducto]
}

resource "helm_release" "vllm_stack" {
  count = var.enable_vllm_stack ? 1 : 0

  name             = "vllm-stack"
  repository       = "https://vllm-project.github.io/production-stack"
  chart            = "vllm-stack"
  version          = "0.1.7"
  namespace        = "reducto"
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
    helm_release.nvidia_device_plugin
  ]
}
