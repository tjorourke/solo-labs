terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

# Portfolio A: the account that also hosts the gateway's and the registry's
# source identities (the "shared services" account in the customer picture).
provider "aws" {
  alias   = "acct_a"
  profile = var.account_a_profile
  region  = var.region_a
}

# Portfolio B: a second, unrelated account. Only IAM is created here.
provider "aws" {
  alias   = "acct_b"
  profile = var.account_b_profile
  region  = var.region_b
}
