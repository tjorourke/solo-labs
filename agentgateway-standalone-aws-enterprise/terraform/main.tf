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
    # Generates the STS signing key, so the lab needs no openssl step and the
    # private key never sits in the repository.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Lab       = "agentgateway-standalone-aws-enterprise"
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

# Ubuntu 24.04 LTS, arm64 (Graviton). Part 1 runs Amazon Linux 2023 and this one
# cannot, which is the single most useful thing this lab found:
#
#   The OSS binary is a static musl build and runs on anything. The enterprise
#   binary is aarch64-unknown-linux-gnu, dynamically linked, and needs glibc 2.39.
#   Amazon Linux 2023 ships glibc 2.34, so the installer succeeds, the binary
#   lands, and then:
#
#     /usr/local/bin/agentgateway: /lib64/libc.so.6: version `GLIBC_2.39' not
#     found (required by /usr/local/bin/agentgateway)
#
#   The installer's own message is "the downloaded agentgateway binary does not
#   run on this system", which does not name glibc, so the first instinct is to
#   suspect the architecture. It is not the architecture.
#
# Ubuntu 24.04 ships glibc 2.39 exactly, so it is the oldest LTS that works.
# Verify before changing this:
#   docker run --rm --platform linux/arm64 -v .:/x ubuntu:24.04 /x/agentgateway --version
data "aws_ssm_parameter" "ubuntu2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
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

  # The STS listens on loopback only. Nothing outside the node has any business
  # minting tokens, and the proxy is the only caller.
  sts_port = 7777
}
