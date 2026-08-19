locals {
  elasticache_url = var.enable_elasticache ? sensitive(format(
    "rediss://:%s@%s:%d",
    urlencode(random_password.elasticache_auth_token[0].result),
    aws_elasticache_replication_group.reducto[0].primary_endpoint_address,
    var.elasticache_port,
  )) : null
}

resource "random_password" "elasticache_auth_token" {
  count = var.enable_elasticache ? 1 : 0

  length  = 32
  special = false
}

resource "aws_elasticache_subnet_group" "reducto" {
  count = var.enable_elasticache ? 1 : 0

  name       = "${var.cluster_name}-cache"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_parameter_group" "reducto" {
  count = var.enable_elasticache ? 1 : 0

  name   = "${var.cluster_name}-valkey8"
  family = "valkey8"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_security_group" "reducto_elasticache" {
  count = var.enable_elasticache ? 1 : 0

  name_prefix = "${var.cluster_name}-cache-"
  description = "Allow Reducto EKS workloads to reach ElastiCache"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Valkey from EKS nodes"
    from_port       = var.elasticache_port
    to_port         = var.elasticache_port
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  tags = {
    Name = "${var.cluster_name}-cache"
  }
}

resource "aws_elasticache_replication_group" "reducto" {
  count = var.enable_elasticache ? 1 : 0

  replication_group_id = substr("reducto-${lower(replace(var.cluster_name, "/[^a-z0-9-]/", "-"))}", 0, 40)
  description          = "Managed Valkey for ${var.cluster_name}"

  engine         = "valkey"
  engine_version = var.elasticache_engine_version
  node_type      = var.elasticache_node_type
  port           = var.elasticache_port

  num_cache_clusters         = var.elasticache_replica_count + 1
  automatic_failover_enabled = var.elasticache_replica_count > 0
  multi_az_enabled           = var.elasticache_replica_count > 0

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.elasticache_auth_token[0].result
  auth_token_update_strategy = "SET"

  subnet_group_name          = aws_elasticache_subnet_group.reducto[0].name
  parameter_group_name       = aws_elasticache_parameter_group.reducto[0].name
  security_group_ids         = [aws_security_group.reducto_elasticache[0].id]
  snapshot_retention_limit   = var.elasticache_snapshot_retention_limit
  apply_immediately          = var.elasticache_apply_immediately
  auto_minor_version_upgrade = true
}
