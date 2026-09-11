# ---------------------------------------------------------------------------
# Amazon Cognito as the primary identity provider.
#
# It is regional and managed, so unlike a self-hosted Keycloak there is no instance
# to keep alive inside a lab about high availability. It covers:
#
#   - JWT validation on the HTTP, LLM and MCP routes (jwtAuth against the pool JWKS)
#   - CEL authorization on claims (cognito:groups, scope, client_id)
#   - browser OIDC login for the admin UI (confidential client, hosted UI domain)
#   - machine-to-machine tokens (resource server + client_credentials grant)
#
# What it cannot do is MCP Dynamic Client Registration, and agentgateway has native
# MCP OAuth adapters for Auth0, Keycloak, Okta, Descope, authentik and Entra ID but
# not Cognito. That one route uses Auth0 as a second issuer instead.
#
# Note on token shapes: Cognito *access* tokens carry client_id and scope but no aud
# claim. agentgateway's jwtAuth treats audiences as optional, so issuer plus JWKS is
# enough. The ID token does carry aud, which is what the UI OIDC flow validates.
# ---------------------------------------------------------------------------

resource "random_id" "cognito_domain" {
  byte_length = 3
}

locals {
  cognito_domain_prefix = coalesce(
    var.cognito_domain_prefix != "" ? var.cognito_domain_prefix : null,
    "${local.name}-${random_id.cognito_domain.hex}",
  )

  cognito_resource_server_id = "urn:agentgateway:api"

  cognito_scopes = {
    "llm.invoke" = "Send requests to the LLM routes"
    "mcp.call"   = "Call tools through the MCP route"
    "admin"      = "Administer the gateway"
  }
}

resource "aws_cognito_user_pool" "this" {
  name = "${local.name}-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 3
      max_length = 256
    }
  }

  lifecycle {
    # The schema block cannot be changed after creation, and Terraform will try.
    ignore_changes = [schema]
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

# Scopes the machine-to-machine client can ask for, and that the CEL rules in
# config.yaml key on.
resource "aws_cognito_resource_server" "api" {
  identifier   = local.cognito_resource_server_id
  name         = "${local.name}-api"
  user_pool_id = aws_cognito_user_pool.this.id

  dynamic "scope" {
    for_each = local.cognito_scopes

    content {
      scope_name        = scope.key
      scope_description = scope.value
    }
  }
}

# ---------------------------------------------------------------------------
# Browser client for the admin UI.
#
# Confidential (has a secret) because agentgateway's oidc policy runs the code
# exchange server-side. The redirect URI has to be https, which is why the lab
# insists on a real certificate.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "ui" {
  name         = "${local.name}-ui"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["${local.gateway_url}/oauth/callback"]
  logout_urls   = [local.gateway_url]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# ---------------------------------------------------------------------------
# Machine-to-machine client.
#
# client_credentials, so every negative test in the lab has a real mint command:
#   curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
#     -d 'grant_type=client_credentials&scope=urn:agentgateway:api/llm.invoke' \
#     https://<domain>.auth.<region>.amazoncognito.com/oauth2/token
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "m2m" {
  name         = "${local.name}-m2m"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    for s in keys(local.cognito_scopes) : "${local.cognito_resource_server_id}/${s}"
  ]

  access_token_validity = 60

  token_validity_units {
    access_token = "minutes"
  }

  depends_on = [aws_cognito_resource_server.api]
}

# A second m2m client deliberately granted only the LLM scope, so the lab can show a
# genuine 403 from the CEL authorization rules rather than a hand-edited token.
resource "aws_cognito_user_pool_client" "m2m_llm_only" {
  name         = "${local.name}-m2m-llm-only"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["${local.cognito_resource_server_id}/llm.invoke"]

  access_token_validity = 60

  token_validity_units {
    access_token = "minutes"
  }

  depends_on = [aws_cognito_resource_server.api]
}

# ---------------------------------------------------------------------------
# Groups and a seeded user for the browser flow. The UI authorization rule in
# config.yaml allows only members of the platform group.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_group" "platform" {
  name         = "platform"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Allowed into the agentgateway admin UI"
}

resource "aws_cognito_user_group" "viewer" {
  name         = "viewer"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Can call the APIs but is refused by the admin UI authorization rule"
}

resource "random_password" "cognito_user" {
  length           = 20
  min_special      = 2
  min_numeric      = 2
  min_upper        = 2
  min_lower        = 2
  override_special = "!@#%^&*()-_=+"
}

resource "aws_cognito_user" "platform_admin" {
  user_pool_id = aws_cognito_user_pool.this.id
  username     = var.cognito_test_user_email
  password     = random_password.cognito_user.result

  attributes = {
    email          = var.cognito_test_user_email
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "platform_admin" {
  user_pool_id = aws_cognito_user_pool.this.id
  group_name   = aws_cognito_user_group.platform.name
  username     = aws_cognito_user.platform_admin.username
}
