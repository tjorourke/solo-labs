# ---------------------------------------------------------------------------
# The fleet's source of truth for configuration.
#
# agentgateway watches its config file and reloads the dynamic sections when it
# changes, so distributing config to N nodes needs nothing more than an object in
# S3 and a timer that syncs it. No controller, no xDS, no Kubernetes.
# Versioning is on so a bad push can be rolled back to the previous object version.
# ---------------------------------------------------------------------------

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "config" {
  bucket        = "${local.name}-config-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.config.arn,
          "${aws_s3_bucket.config.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.config]
}

# ---------------------------------------------------------------------------
# The config file itself.
#
# Uploaded verbatim from config/config.yaml. Nothing is templated into it:
# everything environment-specific is a $VAR that agentgateway resolves from
# /etc/agentgateway/env at load time, because the whole config file is shell
# expanded before parsing. That is what makes the committed file and the file on
# all three nodes byte-identical.
# ---------------------------------------------------------------------------

resource "aws_s3_object" "config" {
  bucket = aws_s3_bucket.config.id
  key    = "config.yaml"
  source = "${path.module}/../config/config.yaml"
  etag   = filemd5("${path.module}/../config/config.yaml")

  content_type = "application/yaml"
}

# OpenAPI description of the node-local echo service. agentgateway generates MCP
# tools from it, so a plain REST API is exposed as tools with no MCP server involved.
resource "aws_s3_object" "echo_openapi" {
  bucket = aws_s3_bucket.config.id
  key    = "echo-openapi.json"
  source = "${path.module}/../config/echo-openapi.json"
  etag   = filemd5("${path.module}/../config/echo-openapi.json")

  content_type = "application/json"
}

resource "aws_s3_object" "model_costs" {
  bucket = aws_s3_bucket.config.id
  key    = "model-costs.json"
  source = "${path.module}/../config/model-costs.json"
  etag   = filemd5("${path.module}/../config/model-costs.json")

  content_type = "application/json"
}

# Descriptors for the Envoy ratelimit service. The gateway names a domain and
# descriptor keys; this file assigns the actual limits to them.
resource "aws_s3_object" "ratelimit_config" {
  bucket = aws_s3_bucket.config.id
  key    = "ratelimit-config.yaml"
  source = "${path.module}/../config/ratelimit-config.yaml"
  etag   = filemd5("${path.module}/../config/ratelimit-config.yaml")

  content_type = "application/yaml"
}
