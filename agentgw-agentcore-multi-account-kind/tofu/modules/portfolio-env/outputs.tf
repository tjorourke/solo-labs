output "account_id" {
  value = data.aws_caller_identity.this.account_id
}

output "agentregistry_role_arn" {
  value = aws_iam_role.agentregistry_access.arn
}

output "external_id" {
  value     = random_password.external_id.result
  sensitive = true
}

output "invoke_role_arn" {
  value = aws_iam_role.agw_invoke.arn
}

output "region" {
  value = var.region
}
