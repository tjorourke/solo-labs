variable "aws_region" {
  description = "Region to build the lab in. Bedrock model availability is widest in us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource in the lab."
  type        = string
  default     = "agw-ha"
}

variable "tags" {
  description = "Extra tags merged into the provider default_tags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# DNS and TLS
# ---------------------------------------------------------------------------

variable "route53_zone_name" {
  description = <<-EOT
    Public Route53 hosted zone to publish the gateway under, for example
    "example.com". ACM validates the certificate with a DNS record in this zone.
    HTTPS is not optional: Cognito rejects non-localhost http redirect URIs, so the
    admin UI OIDC flow needs a real certificate.
  EOT
  type        = string
}

variable "hostname" {
  description = "Record name created in the zone. The gateway is served at <hostname>.<zone>."
  type        = string
  default     = "agw"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR for the lab VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "single_nat_gateway" {
  description = <<-EOT
    Cost lever. false (default) builds one NAT gateway per AZ so losing an AZ does not
    cost the other two their egress, which is the point of an HA lab. true builds a
    single NAT gateway and saves roughly $0.09/hour at the cost of that property.
  EOT
  type        = bool
  default     = false
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 443. Narrow this to your own address for a real run."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# Fleet
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "Instance type for the gateway nodes. arm64 (Graviton) to match the AMI."
  type        = string
  default     = "t4g.medium"
}

variable "fleet_size" {
  description = "Number of gateway nodes. The lab is written for 3, one per AZ."
  type        = number
  default     = 3
}

variable "ratelimit_image" {
  description = <<-EOT
    Envoy rate limit service image, used for the global (fleet-wide) rate limits.
    Pinned for the same reason the gateway version is: a node the Auto Scaling group
    rebuilds later must run the same thing as its siblings. The upstream `master` tag
    moves, so it is not used here.
  EOT
  type        = string
  default     = "docker.io/envoyproxy/ratelimit:e166091a"
}

variable "agentgateway_version" {
  description = <<-EOT
    agentgateway release to install, with the leading v. Pinned rather than "latest" so a
    node replaced by the Auto Scaling group runs the same build as its siblings.
    1.4.0 is the floor: config.storage.mode=hybrid and the multi-replica Postgres NOTIFY
    fan-out that this lab depends on were not present before it.
  EOT
  type        = string
  default     = "v1.4.1"
}

# ---------------------------------------------------------------------------
# Databases
# ---------------------------------------------------------------------------

variable "aurora_engine_version" {
  description = <<-EOT
    Aurora PostgreSQL engine version. Check what your region actually offers before
    changing it, and keep the major in step with the parameter group family:
      aws rds describe-db-engine-versions --engine aurora-postgresql \
        --query 'DBEngineVersions[].EngineVersion' --output text
  EOT
  type        = string
  default     = "16.14"
}

variable "aurora_min_capacity" {
  description = "Aurora Serverless v2 minimum ACUs. 0.5 is the floor and keeps the idle cost down."
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity" {
  description = "Aurora Serverless v2 maximum ACUs."
  type        = number
  default     = 4
}

variable "redis_node_type" {
  description = "ElastiCache node type for the global rate limit counters."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_node_count" {
  description = "ElastiCache nodes. 2 gives a multi-AZ replica; drop to 1 to save about $0.016/hour."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "cognito_domain_prefix" {
  description = <<-EOT
    Prefix for the Cognito hosted UI domain, which becomes
    https://<prefix>.auth.<region>.amazoncognito.com. Must be globally unique. Leave empty
    to have a random suffix appended to var.name.
  EOT
  type        = string
  default     = ""
}

variable "cognito_test_user_email" {
  description = "Email for the seeded Cognito test user used in the browser OIDC demo."
  type        = string
  default     = "platform-admin@example.com"
}

variable "auth0_issuer" {
  description = <<-EOT
    Optional second issuer, used only on the MCP OAuth route. agentgateway ships a native
    Auth0 provider adapter, which Cognito cannot substitute for because Cognito has no
    Dynamic Client Registration. Format: https://<tenant>.<region>.auth0.com
    Leave empty to omit the DCR-capable MCP route entirely.
  EOT
  type        = string
  default     = ""
}

variable "auth0_audience" {
  description = "Auth0 API identifier (audience) for the MCP route, for example urn:agentgateway:mcp."
  type        = string
  default     = "urn:agentgateway:mcp"
}

# ---------------------------------------------------------------------------
# LLM providers
# ---------------------------------------------------------------------------

variable "openai_api_key" {
  description = "OpenAI API key. Stored in Secrets Manager, never written to the config file."
  type        = string
  sensitive   = true
  default     = ""
}

variable "anthropic_api_key" {
  description = "Anthropic API key. Stored in Secrets Manager, never written to the config file."
  type        = string
  sensitive   = true
  default     = ""
}

variable "bedrock_model" {
  description = "Bedrock model id reached through the instance IAM role."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_guardrail_enabled" {
  description = "Create a Bedrock Guardrail and wire it in as the cloud-native prompt guard layer."
  type        = bool
  default     = true
}
