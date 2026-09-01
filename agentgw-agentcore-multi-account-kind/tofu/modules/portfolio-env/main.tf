# One "portfolio environment": the two IAM roles a portfolio account needs.
#
#  1. AgentRegistryAccess-<env>  - assumed by the AgentRegistry control plane to
#     DEPLOY agents (create AgentCore runtimes, execution roles, S3 source
#     bundles, log groups). Mirrors the CloudFormation stack `arctl runtime
#     setup bedrock-agent-core` generates, minus the managed-Gateway EC2,
#     AppConfig and Cognito statements this lab does not use.
#  2. agw-invoke-agentcore-<env> - assumed by the single agentgateway per
#     backend to INVOKE runtimes. Deliberately tiny.
#
# Both trust policies pin the exact source principal with aws:PrincipalArn.
# (arctl's own template trusts the account root with only an ExternalId
# condition; this is the tightened version.)

data "aws_caller_identity" "this" {}

resource "random_password" "external_id" {
  length  = 32
  special = false
}

# --- 1. The registry's control-plane role -----------------------------------

resource "aws_iam_role" "agentregistry_access" {
  name = "AgentRegistryAccess-${var.env_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.trusted_account_id}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = random_password.external_id.result }
          ArnEquals    = { "aws:PrincipalArn" = var.ar_control_user_arn }
        }
      },
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.trusted_account_id}:root" }
        Action    = "sts:TagSession"
        Condition = {
          ArnEquals = { "aws:PrincipalArn" = var.ar_control_user_arn }
        }
      }
    ]
  })
  tags = { Purpose = "AgentRegistry", ManagedBy = "OpenTofu", Env = var.env_name }
}

resource "aws_iam_role_policy_attachment" "agentcore_full_access" {
  role       = aws_iam_role.agentregistry_access.name
  policy_arn = "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess"
}

# The supplemental statements from arctl's template that plain runtime
# deployments actually use. BedrockAgentCoreFullAccess carries the
# bedrock-agentcore:* and ECR-pull grants.
resource "aws_iam_role_policy" "supplemental" {
  name = "BedrockAgentCoreSupplementalAccess"
  role = aws_iam_role.agentregistry_access.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "IAMCreateAndManageExecutionRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy",
          "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:GetRolePolicy", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/*BedrockAgentCore*",
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/service-role/*BedrockAgentCore*",
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/AmazonBedrockAgentCoreSDKRuntime-*",
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/aws-service-role/bedrock-agentcore.amazonaws.com/*"
        ]
      },
      {
        Sid = "IAMCreatePolicy"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:ListPolicyVersions", "iam:DeletePolicy", "iam:DeletePolicyVersion",
          "iam:CreatePolicyVersion"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:policy/service-role/AmazonBedrockAgentCoreRuntimeExecutionPolicy_*"
        ]
      },
      {
        Sid = "IAMServiceLinkedRole"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:GetServiceLinkedRoleDeletionStatus",
          "iam:DeleteServiceLinkedRole"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/aws-service-role/bedrock-agentcore.amazonaws.com/*"
        ]
        Condition = {
          StringLike = { "iam:AWSServiceName" = "bedrock-agentcore.amazonaws.com" }
        }
      },
      {
        Sid = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:DeleteLogGroup",
          "logs:PutDeliverySource", "logs:PutResourcePolicy", "logs:DeleteResourcePolicy"
        ]
        Resource = [
          "arn:aws:logs:*:${data.aws_caller_identity.this.account_id}:log-group:/aws/bedrock-agentcore/*",
          "arn:aws:logs:*:${data.aws_caller_identity.this.account_id}:log-group:/aws/vendedlogs/bedrock-agentcore/*",
          "arn:aws:logs:*:${data.aws_caller_identity.this.account_id}:delivery-source:*",
          "arn:aws:logs:*:${data.aws_caller_identity.this.account_id}:delivery-destination:*"
        ]
      },
      {
        Sid      = "CloudWatchLogsResourcePolicy"
        Effect   = "Allow"
        Action   = ["logs:PutResourcePolicy", "logs:DeleteResourcePolicy", "logs:DescribeResourcePolicies"]
        Resource = "*"
      },
      {
        Sid = "S3SourceBundles"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:PutObject", "s3:GetObject", "s3:ListBucket",
          "s3:ListBucketVersions", "s3:GetBucketLocation", "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketVersioning", "s3:PutBucketPolicy", "s3:GetBucketPolicy",
          "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutLifecycleConfiguration",
          "s3:PutObjectTagging", "s3:GetObjectTagging", "s3:PutBucketTagging", "s3:GetBucketTagging"
        ]
        Resource = [
          "arn:aws:s3:::bedrock-agentcore-codebuild-sources-*",
          "arn:aws:s3:::bedrock-agentcore-codebuild-sources-*/*",
          "arn:aws:s3:::agentcore-*",
          "arn:aws:s3:::agentcore-*/*",
          "arn:aws:s3:::are-*",
          "arn:aws:s3:::are-*/*"
        ]
      }
    ]
  })
}

# One-time per account: Bedrock third-party model access (the Anthropic
# use-case form + agreement). scripts/33-model-access.sh submits these under
# this role; a fresh AWS account cannot invoke Anthropic models until then.
resource "aws_iam_role_policy" "model_access" {
  name = "BedrockModelAccessManagement"
  role = aws_iam_role.agentregistry_access.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ModelAccessManagement"
        Effect = "Allow"
        Action = [
          "bedrock:PutUseCaseForModelAccess", "bedrock:GetUseCaseForModelAccess",
          "bedrock:ListFoundationModelAgreementOffers", "bedrock:CreateFoundationModelAgreement",
          "bedrock:GetFoundationModelAvailability", "bedrock:ListFoundationModels",
          "aws-marketplace:Subscribe", "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:AcceptAgreementRequest", "aws-marketplace:GetAgreementRequest",
          "aws-marketplace:ListAgreementRequests"
        ]
        Resource = "*"
      },
      {
        Sid      = "CloudTrailEvidence"
        Effect   = "Allow"
        Action   = "cloudtrail:LookupEvents"
        Resource = "*"
      },
      {
        # Needed only when a Runtime is BOUND to a registry-managed Gateway
        # (the 51-mismatch-demo): identity resolution + the AppConfig-backed
        # egress policy publisher, from arctl's own CloudFormation template.
        Sid      = "GatewayBindingIdentity"
        Effect   = "Allow"
        Action   = ["iam:GetOutboundWebIdentityFederationInfo", "iam:EnableOutboundWebIdentityFederation"]
        Resource = "*"
      },
      {
        Sid    = "GatewayBindingAppConfig"
        Effect = "Allow"
        Action = [
          "appconfig:ListApplications", "appconfig:CreateApplication", "appconfig:TagResource",
          "appconfig:GetApplication", "appconfig:ListEnvironments", "appconfig:CreateEnvironment",
          "appconfig:GetEnvironment", "appconfig:DeleteEnvironment", "appconfig:ListConfigurationProfiles",
          "appconfig:CreateConfigurationProfile", "appconfig:DeleteConfigurationProfile",
          "appconfig:ListDeploymentStrategies", "appconfig:CreateDeploymentStrategy",
          "appconfig:CreateHostedConfigurationVersion", "appconfig:ListHostedConfigurationVersions",
          "appconfig:DeleteHostedConfigurationVersion", "appconfig:StartDeployment"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- 2. The gateway's invoke role --------------------------------------------

resource "aws_iam_role" "agw_invoke" {
  name = "agw-invoke-agentcore-${var.env_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.trusted_account_id}:root" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          ArnEquals = { "aws:PrincipalArn" = var.agw_ambient_user_arn }
        }
      }
    ]
  })
  tags = { Purpose = "AgentgatewayInvoke", ManagedBy = "OpenTofu", Env = var.env_name }
}

# Scoped to this environment's region. Production tightens Resource to the
# exact runtime ARNs once they exist; the wildcard keeps the lab one-shot.
resource "aws_iam_role_policy" "agw_invoke" {
  name = "AgentCoreInvoke"
  role = aws_iam_role.agw_invoke.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAgentCoreRuntimes"
        Effect = "Allow"
        Action = "bedrock-agentcore:InvokeAgentRuntime"
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.this.account_id}:runtime/*",
          "arn:aws:bedrock-agentcore:${var.region}:${data.aws_caller_identity.this.account_id}:runtime/*/runtime-endpoint/*"
        ]
      }
    ]
  })
}
