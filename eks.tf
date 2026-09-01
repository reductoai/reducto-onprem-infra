module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1"

  name               = var.cluster_name
  kubernetes_version = "1.35"

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = true

  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  cloudwatch_log_group_retention_in_days = 90
  tags                                   = var.tags

  addons = {
    coredns = {
      addon_version = "v1.13.1-eksbuild.1"
      configuration_values = jsonencode({
        autoScaling = {
          enabled     = true
          minReplicas = 2
          maxReplicas = 12
        }
        resources = {
          limits = {
            memory = "200Mi"
          }
          requests = {
            cpu    = "200m"
            memory = "200Mi"
          }
        }
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key      = "worker-type"
                      operator = "In"
                      values   = ["system"]
                    },
                  ]
                }
              ]
            }
          }
        }
      })
    }

    eks-pod-identity-agent = {
      addon_version  = "v1.3.10-eksbuild.2"
      before_compute = true
      configuration_values = jsonencode({
        resources = {
          limits = {
            memory = "40Mi"
          }
          requests = {
            cpu    = "10m"
            memory = "40Mi"
          }
        }
      })
    }

    kube-proxy = {
      addon_version  = "v1.35.0-eksbuild.2"
      before_compute = true
      configuration_values = jsonencode({
        resources = {
          limits = {
            memory = "100Mi"
          }
          requests = {
            cpu    = "10m"
            memory = "100Mi"
          }
        }
      })
    }

    vpc-cni = {
      addon_version            = "v1.21.1-eksbuild.3"
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa_role.arn
      configuration_values = jsonencode({
        resources = {
          limits = {
            memory = "256Mi"
          }
          requests = {
            cpu    = "50m"
            memory = "256Mi"
          }
        }
      })
    }

    aws-ebs-csi-driver = {
      addon_version            = "v1.55.0-eksbuild.1"
      service_account_role_arn = module.ebs_csi_irsa_role.arn
      configuration_values = jsonencode({
        controller = {
          affinity = {
            nodeAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = {
                nodeSelectorTerms = [
                  {
                    matchExpressions = [
                      {
                        key      = "worker-type"
                        operator = "In"
                        values   = ["system"]
                      },
                    ]
                  }
                ]
              }
            }
          }
          tolerations = [
            {
              key      = "CriticalAddonsOnly"
              operator = "Exists"
            }
          ]
        }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # aws ssm get-parameter --name /aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/x86_64/standard/recommended/release_version --region us-west-2 --query "Parameter.Value" --output text
  eks_managed_node_groups = merge(
    {
      system = {
        ami_type                       = "AL2023_x86_64_STANDARD"
        instance_types                 = ["m5.large"]
        use_latest_ami_release_version = false
        ami_release_version            = "1.35.0-20260129"
        enable_monitoring              = true

        min_size     = 2
        max_size     = 10
        desired_size = 3

        labels = {
          worker-type = "system"
        }

        taints = {
          addons = {
            key    = "CriticalAddonsOnly"
            value  = "true"
            effect = "NO_SCHEDULE"
          },
        }
      }
    },
    var.enable_gpu_managed_node_group ? {
      system_gpu = {
        ami_type                       = "AL2023_x86_64_NVIDIA"
        instance_types                 = ["p5.48xlarge"]
        use_latest_ami_release_version = false
        ami_release_version            = "1.35.0-20260129"
        enable_monitoring              = true

        min_size     = 1
        max_size     = 2
        desired_size = 0

        labels = {
          worker-type              = "system-gpu"
          gpu_arch                 = "NVIDIAH100"
          "nvidia.com/gpu.present" = "true"
        }

        block_device_mappings = {
          root = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = 200
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }

        taints = {
          gpu = {
            key    = "nvidia.com/gpu"
            value  = "Exists"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {}
  )

  node_security_group_tags = {
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}" = null
  }
}

module "vpc_cni_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "v6.4.0"

  name            = "${var.cluster_name}-vpc-cni"
  use_name_prefix = true

  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "v6.4.0"

  name            = "${var.cluster_name}-ebs-csi-controller"
  use_name_prefix = true

  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_security_group_rule" "allow_eks_cluster_access_from_vpc" {
  description       = "Allow EKS Control Plane API access from VPC"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.eks.cluster_security_group_id
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "webhook_admission_inbound" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
}

resource "aws_security_group_rule" "webhook_admission_outbound" {
  type                     = "egress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
}
resource "aws_security_group_rule" "allow_all_intra_node_traffic" {
  description              = "Allow all traffic between nodes"
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = -1
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "allow_all_cluster_and_nodes_traffic_ingress" {
  description              = "Allow all traffic between cluster and nodes"
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = -1
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "allow_all_cluster_and_nodes_traffic" {
  description              = "Allow all traffic between cluster and nodes"
  type                     = "egress"
  from_port                = -1
  to_port                  = -1
  protocol                 = -1
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = module.eks.node_security_group_id
}
