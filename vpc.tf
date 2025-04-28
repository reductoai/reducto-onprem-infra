data "aws_availability_zones" "available" {}

locals {
  azs                   = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets_cidrs = length(var.private_subnets) != 0 ? var.private_subnets : [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 2, k)]
  public_subnets_cidrs  = length(var.public_subnets) != 0 ? var.public_subnets : [for k, v in local.azs : cidrsubnet(cidrsubnet(var.vpc_cidr, 2, 3), 2, k)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.14"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # this setup makes the private subnets as large as possible (/18), public subnets /20 and leaving one /20 subnet for future uses
  # https://www.davidc.net/sites/default/subnets/subnets.html?network=10.100.0.0&mask=16&division=13.3d40
  private_subnets = local.private_subnets_cidrs
  public_subnets  = local.public_subnets_cidrs

  // One NAT Gateway per availability zone
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  // https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html#cluster-endpoint-private
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}"  = "shared"
    "kubernetes.io/role/internal-elb"            = 1
    "karpenter.sh/discovery"                     = var.cluster_name
    "karpenter.sh/discovery/${var.cluster_name}" = "shared"
  }
}

resource "aws_db_subnet_group" "default" {
  name       = var.cluster_name
  subnet_ids = module.vpc.private_subnets
}