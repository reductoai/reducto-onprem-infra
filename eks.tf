module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.26.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = true

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  cluster_addons = {
    coredns = {
      addon_version     = "v1.11.4-eksbuild.24"
      resolve_conflicts = "OVERWRITE"
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
      addon_version     = "v1.3.4-eksbuild.1"
      resolve_conflicts = "OVERWRITE"
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
      addon_version     = "v1.32.6-eksbuild.13"
      resolve_conflicts = "OVERWRITE"
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
      addon_version     = "v1.20.4-eksbuild.1"
      resolve_conflicts = "OVERWRITE"
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
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
      addon_version            = "v1.37.0-eksbuild.1"
      resolve_conflicts        = "OVERWRITE"

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

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.large"]

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

    system_gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = ["p5.48xlarge"]

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

    // capacity for boostrapping workloads.
    // For example: cert-manager and nginx Jobs
    // before Karpenter could even provision capacity
    startup = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.large"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}" = null
  }
}

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.44.1"

  role_name             = "${var.cluster_name}-ebs-csi-controller"
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
