terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }
}

# Credentials and account come from the environment (AWS_PROFILE / SSO). Nothing
# account-specific is written into this module on purpose.
provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Lab       = "istio-ambient-poc-eks"
        ManagedBy = "opentofu"
      },
      var.tags,
    )
  }
}
