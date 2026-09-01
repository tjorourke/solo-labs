variable "account_a_profile" {
  description = "AWS CLI profile for portfolio account A (also hosts the gateway/registry source identities)."
  type        = string
}

variable "account_b_profile" {
  description = "AWS CLI profile for portfolio account B."
  type        = string
}

variable "region_a" {
  description = "AgentCore region for portfolio A."
  type        = string
  default     = "us-east-1"
}

variable "region_b" {
  description = "AgentCore region for portfolio B."
  type        = string
  default     = "us-west-2"
}
