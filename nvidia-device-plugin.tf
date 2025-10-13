resource "helm_release" "nvidia_device_plugin" {
  count = var.enable_nvidia_device_plugin ? 1 : 0

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.17.4"

  values = [file("values/nvidia-device-plugin.yaml")]


  depends_on = [module.eks]
}
