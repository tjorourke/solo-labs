variable "env_name" {
  description = "Environment name, e.g. portfolio-a."
  type        = string
}

variable "region" {
  description = "AgentCore region for this environment (scopes the invoke grant)."
  type        = string
}

variable "trusted_account_id" {
  description = "Account that hosts the gateway and registry source identities."
  type        = string
}

variable "agw_ambient_user_arn" {
  description = "ARN of the gateway's ambient IAM user. Only this principal may assume the invoke role."
  type        = string
}

variable "ar_control_user_arn" {
  description = "ARN of the AgentRegistry control-plane IAM user. Only this principal may assume the AgentRegistryAccess role."
  type        = string
}
