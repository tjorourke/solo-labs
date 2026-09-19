terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    # The two LoadBalancer Services live here rather than in yaml/ because each one
    # needs a certificate ARN that does not exist until ACM has issued it. Splitting
    # them across a tofu apply and a kubectl apply is what made this hand-made in the
    # first place: somebody has to paste the ARN, and then nothing in the repository
    # says what the running cluster is.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Lab       = "agentgateway-inference-task-routing-eks"
        ManagedBy = "opentofu"
      },
      var.tags,
    )
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
