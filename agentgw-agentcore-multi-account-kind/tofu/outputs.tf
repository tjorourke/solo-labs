output "portfolio_a" {
  value = {
    account_id            = module.portfolio_a.account_id
    region                = module.portfolio_a.region
    agentregistry_role    = module.portfolio_a.agentregistry_role_arn
    invoke_role           = module.portfolio_a.invoke_role_arn
  }
}

output "portfolio_b" {
  value = {
    account_id            = module.portfolio_b.account_id
    region                = module.portfolio_b.region
    agentregistry_role    = module.portfolio_b.agentregistry_role_arn
    invoke_role           = module.portfolio_b.invoke_role_arn
  }
}

output "portfolio_a_external_id" {
  value     = module.portfolio_a.external_id
  sensitive = true
}

output "portfolio_b_external_id" {
  value     = module.portfolio_b.external_id
  sensitive = true
}

output "agw_ambient_access_key_id" {
  value = aws_iam_access_key.agw_ambient.id
}

output "agw_ambient_secret_access_key" {
  value     = aws_iam_access_key.agw_ambient.secret
  sensitive = true
}

output "ar_control_access_key_id" {
  value = aws_iam_access_key.ar_control.id
}

output "ar_control_secret_access_key" {
  value     = aws_iam_access_key.ar_control.secret
  sensitive = true
}
