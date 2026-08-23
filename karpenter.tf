module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.12.0"

  cluster_name = var.cluster_name

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  depends_on = [module.eks]
}

resource "helm_release" "karpenter-crd" {
  namespace  = "kube-system"
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = "1.8.3"
  wait       = false
  timeout    = var.helm_release_timeout

  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.8.3"
  wait       = false
  timeout    = var.helm_release_timeout

  values = [
    <<-EOT
    controller:
      resources:
        requests:
          cpu: 500m
          memory: 2Gi
        limits:
          memory: 2Gi
    nodeSelector:
      worker-type: system
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
    settings:
      clusterName: ${var.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
      vmMemoryOverheadPercent: 0.001
      featureGates:
        spotToSpotConsolidation: true
    serviceMonitor:
      enabled: true
    EOT
  ]
  depends_on = [
    helm_release.karpenter-crd,
    helm_release.prometheus_crds,
    module.karpenter,
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  wait      = true
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
      - alias: al2023@v20260120
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 200Gi
            volumeType: gp3
            throughput: 250
      role: ${module.karpenter.node_iam_role_name}
      detailedMonitoring: true
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags: ${jsonencode(merge(var.tags, { "karpenter.sh/discovery" = var.cluster_name }))}
  YAML

  # Keep VPC/NAT egress until Karpenter finalizers terminate dynamic nodes.
  depends_on = [helm_release.karpenter, module.vpc]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  wait      = true
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          expireAfter: Never
          terminationGracePeriod: 1h
          nodeClassRef:
            name: default
            group: karpenter.k8s.aws
            kind: EC2NodeClass
          requirements:
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "kubernetes.io/os"
              operator: In
              values: ["linux"]
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["8", "16"]
            - key: "karpenter.k8s.aws/instance-capability-flex"
              operator: In
              values: ["false"]
      disruption:
        budgets:
        - nodes: 100%
        consolidateAfter: 3m
        consolidationPolicy: WhenEmptyOrUnderutilized
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class,
    module.vpc,
  ]
}
