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

# Dedicated, tainted node pool for gVisor-isolated agent-sandbox workloads
# (see gvisor.tf / agent-sandbox.tf). userData installs runsc + registers the
# containerd runtime handler at boot via a nodeadm NodeConfig merge, so runsc
# is present before the first pod schedules: no DaemonSet, no restart race.
# On-demand only (untrusted-code isolation nodes should not be
# spot-interruptible mid-task), nitro c/m/r 2-31 vCPU, generation >= 7.
resource "kubectl_manifest" "karpenter_sandbox_node_class" {
  count     = var.enable_agent_sandbox ? 1 : 0
  wait      = true
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: reducto-sandbox
    spec:
      amiSelectorTerms:
      - alias: al2023@v20260120
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 150Gi
            volumeType: gp3
            encrypted: true
      role: ${module.karpenter.node_iam_role_name}
      detailedMonitoring: true
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags: ${jsonencode(merge(var.tags, { "karpenter.sh/discovery" = var.cluster_name }))}
      userData: |
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUNDARY"

        --BOUNDARY
        Content-Type: text/x-shellscript; charset="us-ascii"

        #!/bin/bash
        # Install gVisor (runsc) from the upstream release channel before
        # containerd starts, so the runsc runtime handler registered by the
        # NodeConfig below is backed by real binaries at first boot.
        set -euo pipefail
        REL="20260622"
        ARCH=$(uname -m)
        GCS_PREFIX="https://storage.googleapis.com/gvisor/releases/release/$${REL}/$${ARCH}"
        for f in runsc containerd-shim-runsc-v1; do
          curl -sSfL --retry 3 --max-redirs 5 -o "/usr/local/bin/$${f}" "$${GCS_PREFIX}/$${f}"
          curl -sSfL --retry 3 --max-redirs 5 -o "/tmp/$${f}.sha512" "$${GCS_PREFIX}/$${f}.sha512"
          sed "s| .*| /usr/local/bin/$${f}|" "/tmp/$${f}.sha512" | sha512sum -c -
          chmod 0755 "/usr/local/bin/$${f}"
          rm -f "/tmp/$${f}.sha512"
        done
        logger -t gvisor-runsc-install "release=$${REL} arch=$${ARCH}"

        --BOUNDARY
        Content-Type: application/node.eks.aws

        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          containerd:
            config: |
              [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
                runtime_type = 'io.containerd.runsc.v1'
              [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc.options]
                BinaryName = '/usr/local/bin/runsc'

        --BOUNDARY--
  YAML

  depends_on = [helm_release.karpenter, module.vpc]
}

resource "kubectl_manifest" "karpenter_sandbox_node_pool" {
  count     = var.enable_agent_sandbox ? 1 : 0
  wait      = true
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: reducto-sandbox
    spec:
      disruption:
        budgets:
        - nodes: 25%
        consolidateAfter: 10m
        # "Balanced" requires a newer Karpenter version than the one this
        # repo pins (1.8.3); its NodePool CRD only supports WhenEmpty and
        # WhenEmptyOrUnderutilized. The latter also matches this repo's
        # existing default NodePool.
        consolidationPolicy: WhenEmptyOrUnderutilized
      template:
        metadata:
          labels:
            node-type: reducto-sandbox
        spec:
          expireAfter: Never
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: reducto-sandbox
          requirements:
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c", "m", "r"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-capability-flex"
              operator: In
              values: ["false"]
            - key: "karpenter.k8s.aws/instance-generation"
              # This Karpenter version's NodePool CRD doesn't support "Gte"
              # (only Gt/Lt) — Gt "6" is equivalent for an integer field.
              operator: Gt
              values: ["6"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: Gt
              values: ["1"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: Lt
              values: ["32"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
          taints:
            - key: reducto.ai/sandbox
              value: "true"
              effect: NoSchedule
  YAML

  depends_on = [
    kubectl_manifest.karpenter_sandbox_node_class,
    module.vpc,
  ]
}
