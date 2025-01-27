data "aws_iam_policy_document" "reducto" {
    statement {
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [module.eks.oidc_provider_arn]
      }

      condition {
        test     = "StringLike"
        variable = "${module.eks.oidc_provider}:sub"

        values = [
          "system:serviceaccount:reducto*:*",
        ]
      }

      condition {
        test     = "StringLike"
        variable = "${module.eks.oidc_provider}:aud"

        values = [
          "sts.amazonaws.com",
        ]
      }
    }
}

resource "aws_iam_role" "reducto" {
  name = "reducto-${var.cluster_name}"

  assume_role_policy = data.aws_iam_policy_document.reducto.json
}

resource "aws_iam_role_policy" "reducto" {
  name = "reducto-${var.cluster_name}"
  role = aws_iam_role.reducto.name
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:*"
        ],
        Resource = [
          aws_s3_bucket.reducto_storage.arn,
          "${aws_s3_bucket.reducto_storage.arn}/*",
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "textract:DetectDocumentText",
        ],
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "bedrock:InvokeModel",
        ],
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-5-sonnet-20240620-v1:0"
        ]
      },
    ]
  })
}
