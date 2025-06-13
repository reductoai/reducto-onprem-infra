resource "random_password" "db_password" {
  length  = 20
  special = false
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  manage_master_user_password = false
  username                    = var.db_username
  password                    = random_password.db_password.result

  # When using RDS Proxy w/ IAM auth - Database must be username/password auth, not IAM
  iam_database_authentication_enabled = false

  identifier            = var.cluster_name
  engine                = "postgres"
  engine_version        = "16.8"
  family                = "postgres16" # DB parameter group
  major_engine_version  = "16"         # DB option group
  instance_class        = var.db_instance_class

  storage_type          = "gp3"
  allocated_storage     = 20
  max_allocated_storage = 200
  storage_encrypted = true

  port                  = 5432
  apply_immediately     = true

  db_subnet_group_name   = aws_db_subnet_group.default.id
  vpc_security_group_ids = [module.rds_sg.security_group_id]
  multi_az               = var.db_multi_az

  backup_retention_period = 7
  backup_window = "03:00-06:00"
  maintenance_window = "sun:06:00-sun:07:00"
  deletion_protection     = var.db_deletion_protection
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot = true
  publicly_accessible = false
  skip_final_snapshot = false

  performance_insights_enabled = true
  performance_insights_retention_period = 7

  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

}

module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

  name   = "${var.cluster_name}-rds"
  vpc_id = module.vpc.vpc_id

  revoke_rules_on_delete = true

  ingress_with_cidr_blocks = [
    {
      description = "Private subnet PostgreSQL access"
      rule        = "postgresql-tcp"
      cidr_blocks = var.vpc_cidr
    }
  ]

   egress_with_cidr_blocks = [
    {
      description = "Database subnet PostgreSQL access"
      rule        = "postgresql-tcp"
      cidr_blocks = var.vpc_cidr
    },
  ]
}

resource "aws_secretsmanager_secret" "superuser" {
  name        = "rds-${var.cluster_name}"
  description = "Database superuser, ${var.db_username}, database connection values"
}

locals {
  database_url = "postgresql://${var.db_username}:${random_password.db_password.result}@${split(":", module.rds.db_instance_endpoint)[0]}/postgres?sslmode=require"
}

resource "aws_secretsmanager_secret_version" "superuser" {
  secret_id = aws_secretsmanager_secret.superuser.id
  secret_string = jsonencode({
    username            = var.db_username
    password            = random_password.db_password.result
    database_url = local.database_url
  })
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name               = "${var.cluster_name}-rds-enhanced-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_enhanced_monitoring.json
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

data "aws_iam_policy_document" "rds_enhanced_monitoring" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}


