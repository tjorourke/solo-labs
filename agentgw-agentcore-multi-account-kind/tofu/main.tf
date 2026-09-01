# Two portfolio environments in two AWS accounts, plus the two source
# identities in account A that everything else trusts:
#
#   agw-ambient       - the single agentgateway's ambient identity. May only
#                       sts:AssumeRole into the two invoke roles. In production
#                       this is the gateway's IRSA role; on kind it is an IAM
#                       user whose key lives in one cluster Secret.
#   ar-control-plane  - the AgentRegistry server's ambient identity. May only
#                       sts:AssumeRole into the two AgentRegistryAccess roles.

data "aws_caller_identity" "acct_a" {
  provider = aws.acct_a
}

resource "aws_iam_user" "agw_ambient" {
  provider = aws.acct_a
  name     = "agw-ambient"
  tags     = { Purpose = "AgentgatewaySourceIdentity", ManagedBy = "OpenTofu" }
}

resource "aws_iam_access_key" "agw_ambient" {
  provider = aws.acct_a
  user     = aws_iam_user.agw_ambient.name
}

resource "aws_iam_user" "ar_control" {
  provider = aws.acct_a
  name     = "ar-control-plane"
  tags     = { Purpose = "AgentRegistrySourceIdentity", ManagedBy = "OpenTofu" }
}

resource "aws_iam_access_key" "ar_control" {
  provider = aws.acct_a
  user     = aws_iam_user.ar_control.name
}

module "portfolio_a" {
  source    = "./modules/portfolio-env"
  providers = { aws = aws.acct_a }

  env_name             = "portfolio-a"
  region               = var.region_a
  trusted_account_id   = data.aws_caller_identity.acct_a.account_id
  agw_ambient_user_arn = aws_iam_user.agw_ambient.arn
  ar_control_user_arn  = aws_iam_user.ar_control.arn
}

module "portfolio_b" {
  source    = "./modules/portfolio-env"
  providers = { aws = aws.acct_b }

  env_name             = "portfolio-b"
  region               = var.region_b
  trusted_account_id   = data.aws_caller_identity.acct_a.account_id
  agw_ambient_user_arn = aws_iam_user.agw_ambient.arn
  ar_control_user_arn  = aws_iam_user.ar_control.arn
}

resource "aws_iam_user_policy" "agw_ambient_assume" {
  provider = aws.acct_a
  name     = "assume-invoke-roles"
  user     = aws_iam_user.agw_ambient.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [
          module.portfolio_a.invoke_role_arn,
          module.portfolio_b.invoke_role_arn
        ]
      }
    ]
  })
}

resource "aws_iam_user_policy" "ar_control_assume" {
  provider = aws.acct_a
  name     = "assume-agentregistry-roles"
  user     = aws_iam_user.ar_control.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [
          module.portfolio_a.agentregistry_role_arn,
          module.portfolio_b.agentregistry_role_arn
        ]
      }
    ]
  })
}
