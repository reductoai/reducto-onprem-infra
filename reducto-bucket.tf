resource "aws_s3_bucket" "reducto_storage" {
  bucket_prefix = "${replace(var.cluster_name, "_", "-")}-storage"

  tags = {
    Name        = "Reducto Storage ${var.cluster_name}"
    Environment = var.cluster_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reducto_storage_lifecycle" {
  bucket = aws_s3_bucket.reducto_storage.id

  rule {
    id     = "delete-after-24-hours"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "reducto_storage_public_access_block" {
  bucket = aws_s3_bucket.reducto_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
