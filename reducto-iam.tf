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

    # The sandbox namespaces (reducto-agent-sandbox by default) also match
    # reducto*, and they run untrusted agent code. Sandbox pods get no SA
    # token (Kyverno) and no egress to STS, but nothing there may ever hold
    # this role: exclude them explicitly. Conditions are ANDed.
    dynamic "condition" {
      for_each = var.enable_agent_sandbox ? [1] : []
      content {
        test     = "StringNotLike"
        variable = "${module.eks.oidc_provider}:sub"
        values   = [for ns in sort(local.agent_sandbox_namespaces) : "system:serviceaccount:${ns}:*"]
      }
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
