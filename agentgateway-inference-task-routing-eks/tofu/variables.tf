variable "aws_region" {
  description = "Region the EKS cluster runs in. The certificates are regional, so this has to match."
  type        = string
  default     = "eu-west-2"
}

variable "tags" {
  description = "Extra tags merged into the provider default_tags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to the kubeconfig holding the lab's cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = <<-EOT
    Context within that kubeconfig. Left empty the provider takes whichever context is
    current, which is how you publish the admin UI of a cluster you did not mean to
    touch. Name it.
  EOT
  type        = string
}

variable "namespace" {
  description = "Namespace holding the intake gateway and the Enterprise UI."
  type        = string
  default     = "agentgateway-system"
}

# ---------------------------------------------------------------------------
# DNS and TLS
# ---------------------------------------------------------------------------

variable "route53_zone_name" {
  description = <<-EOT
    Existing public Route53 hosted zone to publish under, for example
    "awslab.example.com". This is read, never created: the zone is delegated from the
    parent domain, and a zone created here would be a new one with new nameservers that
    nothing points at.
  EOT
  type        = string
}

variable "gateway_subdomain" {
  description = "Subdomain for the model endpoint clients post to. Joined to route53_zone_name."
  type        = string
  default     = "agw"
}

variable "ui_subdomain" {
  description = "Subdomain for the Solo Enterprise UI. Joined to route53_zone_name."
  type        = string
  default     = "soloui"
}

# ---------------------------------------------------------------------------
# Who may reach each endpoint
# ---------------------------------------------------------------------------

variable "gateway_allowed_cidrs" {
  description = <<-EOT
    Source ranges for the model endpoint. Open by default, which is the point of it:
    every request carries a JWT the gateway verifies, and OPA decides what the subject
    may reach, so the control is the token rather than the address. Cursor also sends
    chat completions from its own backend rather than from the laptop, so an allowlist
    of your own address would refuse the editor this lab is meant to demonstrate.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ui_allowed_cidrs" {
  description = <<-EOT
    Source ranges for the Enterprise UI. Required, with no default, because the UI is
    not behind the JWT policy the model endpoint is: reaching it is enough to read
    every prompt in the decision log and the spend behind them. scripts/platform/40-public-endpoints.sh
    fills this with the address you are calling from.

    A dynamic home address is the failure this variable causes most: the security group
    keeps allowing an address your ISP has moved on from, the SYN is dropped rather than
    refused, and the browser reports a timeout with nothing in any cluster log. Re-run
    the script to refresh it.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ui_allowed_cidrs) > 0 && !contains(var.ui_allowed_cidrs, "0.0.0.0/0")
    error_message = "ui_allowed_cidrs must name at least one range and cannot be 0.0.0.0/0: the UI has no request authentication in front of it."
  }
}
