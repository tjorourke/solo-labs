terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Lab       = "agentgateway-standalone-aws-ha"
        ManagedBy = "opentofu"
      },
      var.tags,
    )
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Amazon Linux 2023, arm64 (Graviton). agentgateway publishes a linux-arm64 binary,
# so the fleet runs t4g and costs about 20% less than the x86 equivalent.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = var.name

  # Three AZs, or fewer if the region cannot offer three.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names)),
  )

  az_count = length(local.azs)

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Public hostname the fleet is served on. Every OIDC redirect URI, MCP resource
  # identifier and JWT audience in config.yaml is derived from this one value.
  fqdn        = "${var.hostname}.${trimsuffix(data.aws_route53_zone.selected.name, ".")}"
  gateway_url = "https://${local.fqdn}"

  gateway_port   = 3000
  metrics_port   = 15020
  readiness_port = 15021
  admin_port     = 15000
  ratelimit_port = 8081
}
