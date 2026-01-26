data "kubectl_filename_list" "cluster_manifests" {
  pattern = "./manifests/cluster/*.yaml"
}

resource "kubectl_manifest" "cluster_manifests" {
  count     = length(data.kubectl_filename_list.cluster_manifests.matches)
  yaml_body = file(element(data.kubectl_filename_list.cluster_manifests.matches, count.index))

  depends_on = [
    module.eks,
  ]
}
