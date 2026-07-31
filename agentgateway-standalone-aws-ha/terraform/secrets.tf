# ---------------------------------------------------------------------------
# Everything the config file references as a $VAR but must never contain.
#
# One secret holds a JSON document; each node reads it at boot and renders
# /etc/agentgateway/env at mode 0600. The config file in S3 and in git stays free
# of credentials, database endpoints and client secrets.
# ---------------------------------------------------------------------------

# Shared across the fleet, and the reason MCP sessions are portable between nodes.
# agentgateway encrypts MCP session state into the Mcp-Session-Id with AES-256-GCM
# keyed by this value, so any node holding the same key can decode a session another
# node issued. Different keys on different nodes means every request has to land on
# the node that created the session.
resource "random_id" "session_key" {
  byte_length = 32
}

# Protects the browser OIDC cookie for the admin UI. Also has to be fleet-wide, or
# a login on one node is not recognised by the other two.
resource "random_id" "oidc_cookie_secret" {
  byte_length = 32
}

resource "random_password" "database" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "runtime" {
  name                    = "${local.name}-runtime"
  description             = "agentgateway standalone runtime environment for the ${local.name} fleet"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "runtime" {
  secret_id = aws_secretsmanager_secret.runtime.id

  secret_string = jsonencode({
    # Fleet-wide crypto
    SESSION_KEY        = random_id.session_key.hex
    OIDC_COOKIE_SECRET = random_id.oidc_cookie_secret.hex

    # Aurora. maxConnections in config.yaml must be at least 2 for hybrid storage
    # on PostgreSQL, which is enforced at startup.
    AGW_DATABASE_URL = format(
      "postgresql://%s:%s@%s:%s/%s",
      aws_rds_cluster.this.master_username,
      random_password.database.result,
      aws_rds_cluster.this.endpoint,
      aws_rds_cluster.this.port,
      aws_rds_cluster.this.database_name,
    )

    # Public identity of the fleet. Drives the OIDC redirect URI, the MCP resource
    # identifiers and the JWT audiences.
    AGW_PUBLIC_URL = local.gateway_url
    AGW_FQDN       = local.fqdn

    # Cognito: JWT validation for the APIs, browser OIDC for the admin UI
    COGNITO_ISSUER           = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    COGNITO_JWKS_URL         = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/jwks.json"
    COGNITO_AUTHORIZE_URL    = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/authorize"
    COGNITO_TOKEN_URL        = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
    COGNITO_UI_CLIENT_ID     = aws_cognito_user_pool_client.ui.id
    COGNITO_UI_CLIENT_SECRET = aws_cognito_user_pool_client.ui.client_secret
    COGNITO_API_AUDIENCE     = local.cognito_resource_server_id

    # Auth0: second issuer, used only on the MCP route that needs Dynamic Client
    # Registration. Cognito has no DCR and agentgateway has no Cognito MCP adapter.
    AUTH0_ISSUER   = var.auth0_issuer
    AUTH0_JWKS_URL = "${var.auth0_issuer}/.well-known/jwks.json"
    AUTH0_AUDIENCE = var.auth0_audience

    # LLM providers
    OPENAI_API_KEY            = var.openai_api_key
    ANTHROPIC_API_KEY         = var.anthropic_api_key
    BEDROCK_REGION            = var.aws_region
    BEDROCK_MODEL             = var.bedrock_model
    BEDROCK_GUARDRAIL_ID      = var.bedrock_guardrail_enabled ? aws_bedrock_guardrail.this[0].guardrail_id : ""
    BEDROCK_GUARDRAIL_VERSION = var.bedrock_guardrail_enabled ? aws_bedrock_guardrail_version.this[0].version : ""

    # Local sidecars on each node
    RATELIMIT_HOST = "127.0.0.1:${local.ratelimit_port}"
    OTLP_ENDPOINT  = "http://127.0.0.1:4317"
  })
}
