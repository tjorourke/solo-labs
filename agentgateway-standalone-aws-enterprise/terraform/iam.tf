# ---------------------------------------------------------------------------
# Instance role for the gateway nodes.
#
# Deliberately narrow. The nodes need to read one config prefix, read one secret,
# invoke Bedrock, and ship logs and metrics. There are no SSH keys anywhere in the
# lab; shell access is SSM Session Manager, which is why the managed
# AmazonSSMManagedInstanceCore policy is attached.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${local.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "gateway_ssm" {
  role       = aws_iam_role.gateway.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid    = "ReadFleetConfig"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = ["${aws_s3_bucket.config.arn}/*"]
  }

  statement {
    sid       = "ListFleetConfig"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.config.arn]
  }

  statement {
    sid       = "ReadRuntimeSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.runtime.arn]
  }

  # Bedrock is reached with the instance role, so no API key is involved for that
  # provider at all. The cross-region inference profile ids used by the lab resolve
  # to foundation models in several regions, so both ARN shapes are needed.
  statement {
    sid    = "InvokeBedrock"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
      "bedrock:ApplyGuardrail",
    ]

    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/*",
      "arn:${local.partition}:bedrock:${var.aws_region}:${local.account_id}:inference-profile/*",
      "arn:${local.partition}:bedrock:${var.aws_region}:${local.account_id}:guardrail/*",
    ]
  }

  statement {
    sid    = "Observability"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "cloudwatch:PutMetricData",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]

    resources = ["*"]
  }

  # The node stamps its own instance id into every access log line so per-node
  # attribution works, and the HA scripts resolve their peers from the ASG.
  statement {
    sid    = "DescribeSelfAndPeers"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "autoscaling:DescribeAutoScalingGroups",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "${local.name}-gateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

resource "aws_iam_instance_profile" "gateway" {
  name = "${local.name}-gateway"
  role = aws_iam_role.gateway.name
}
