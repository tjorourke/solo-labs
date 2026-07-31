output "gateway_url" {
  description = "Public entrypoint. Every route, the LLM API, the MCP endpoint and the admin UI are served here."
  value       = local.gateway_url
}

output "admin_ui_url" {
  description = "Admin UI, published through the data plane gateway behind Cognito OIDC."
  value       = "${local.gateway_url}/ui"
}

output "alb_dns_name" {
  description = "Raw ALB hostname, for when you want to bypass DNS."
  value       = aws_lb.this.dns_name
}

output "autoscaling_group_name" {
  description = "Auto Scaling group holding the gateway nodes."
  value       = aws_autoscaling_group.gateway.name
}

output "config_bucket" {
  description = "Source of truth for the fleet config. Push config.yaml here to reload all nodes."
  value       = aws_s3_bucket.config.id
}

output "config_push_command" {
  description = "Copy-paste command to publish a config change to the whole fleet."
  value       = "aws s3 cp config/config.yaml s3://${aws_s3_bucket.config.id}/config.yaml"
}

output "log_group" {
  description = "CloudWatch log group carrying every node's access log."
  value       = aws_cloudwatch_log_group.gateway.name
}

output "metrics_namespace" {
  description = "CloudWatch namespace the gateway's Prometheus metrics land in."
  value       = local.metrics_namespace
}

# ---------------------------------------------------------------------------
# Data services
# ---------------------------------------------------------------------------

output "aurora_writer_endpoint" {
  description = "Aurora writer. Holds the request log and the hybrid config overlay."
  value       = aws_rds_cluster.this.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "redis_endpoint" {
  description = "ElastiCache primary, holding the global rate limit counters."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "runtime_secret_arn" {
  description = "Secrets Manager document each node renders into /etc/agentgateway/env."
  value       = aws_secretsmanager_secret.runtime.arn
}

# ---------------------------------------------------------------------------
# Identity. These are what the verification and demo scripts consume.
# ---------------------------------------------------------------------------

output "cognito_issuer" {
  description = "Cognito issuer, matched against the iss claim by jwtAuth."
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "cognito_token_url" {
  description = "Token endpoint used to mint machine-to-machine access tokens."
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

output "cognito_api_audience" {
  description = "Resource server identifier that prefixes every scope."
  value       = local.cognito_resource_server_id
}

output "cognito_m2m_client_id" {
  description = "Machine client holding all three scopes."
  value       = aws_cognito_user_pool_client.m2m.id
}

output "cognito_m2m_client_secret" {
  description = "Secret for the full-scope machine client."
  value       = aws_cognito_user_pool_client.m2m.client_secret
  sensitive   = true
}

output "cognito_m2m_llm_only_client_id" {
  description = "Machine client granted only llm.invoke, used to demonstrate a real 403 on the MCP route."
  value       = aws_cognito_user_pool_client.m2m_llm_only.id
}

output "cognito_m2m_llm_only_client_secret" {
  description = "Secret for the llm-only machine client."
  value       = aws_cognito_user_pool_client.m2m_llm_only.client_secret
  sensitive   = true
}

output "cognito_ui_client_id" {
  description = "Confidential browser client used by the admin UI OIDC flow."
  value       = aws_cognito_user_pool_client.ui.id
}

output "cognito_test_user" {
  description = "Seeded user in the platform group, allowed into the admin UI."
  value       = aws_cognito_user.platform_admin.username
}

output "cognito_test_user_password" {
  description = "Password for the seeded user."
  value       = random_password.cognito_user.result
  sensitive   = true
}

output "mint_token_command" {
  description = "Reproducible command that mints a real access token. Every negative test in the lab uses this rather than a hand-edited JWT."
  value = join(" ", [
    "curl -s -u \"${aws_cognito_user_pool_client.m2m.id}:$COGNITO_M2M_CLIENT_SECRET\"",
    "-d 'grant_type=client_credentials&scope=${local.cognito_resource_server_id}/llm.invoke'",
    "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token",
    "| jq -r .access_token",
  ])
}

# ---------------------------------------------------------------------------
# Bedrock
# ---------------------------------------------------------------------------

output "bedrock_guardrail_id" {
  description = "Guardrail applied as the cloud-native prompt guard layer."
  value       = var.bedrock_guardrail_enabled ? aws_bedrock_guardrail.this[0].guardrail_id : ""
}

output "bedrock_guardrail_version" {
  description = "Pinned guardrail version."
  value       = var.bedrock_guardrail_enabled ? aws_bedrock_guardrail_version.this[0].version : ""
}
