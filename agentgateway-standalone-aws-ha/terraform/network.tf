# ---------------------------------------------------------------------------
# VPC: three public subnets for the ALB, three private subnets for the gateway
# nodes and the managed data services. Nothing that holds state or runs the
# gateway is reachable from the internet.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

# ---------------------------------------------------------------------------
# Egress. The gateway nodes need to reach the OpenAI and Anthropic APIs, the
# Auth0 JWKS endpoint and any remote MCP server, so NAT is required.
# One NAT gateway per AZ by default: a lab about surviving an AZ loss should not
# route all three AZs' egress through a single one.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count = var.single_nat_gateway ? 1 : local.az_count

  domain = "vpc"

  tags = { Name = "${local.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : local.az_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint. The config sync timer runs every 30 seconds on every
# node, so keeping that traffic off the NAT gateways is worth one route entry.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${local.name}-s3" }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entrypoint for the agentgateway fleet"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}, redirected to HTTPS"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "To the gateway nodes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "gateway" {
  name        = "${local.name}-gateway"
  description = "agentgateway nodes. No SSH: access is SSM Session Manager only."
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-gateway" }
}

resource "aws_vpc_security_group_ingress_rule" "gateway_data" {
  security_group_id            = aws_security_group.gateway.id
  description                  = "Data plane from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.gateway_port
  to_port                      = local.gateway_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "gateway_readiness" {
  security_group_id            = aws_security_group.gateway.id
  description                  = "Readiness probe from the ALB target group health check"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.readiness_port
  to_port                      = local.readiness_port
  ip_protocol                  = "tcp"
}

# Node-to-node on the data port. The portable-MCP-session demo drives a session
# created on one node against its siblings, which it reaches from inside the VPC.
resource "aws_vpc_security_group_ingress_rule" "gateway_peer" {
  security_group_id            = aws_security_group.gateway.id
  description                  = "Peer nodes, for the cross-node session demos"
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = local.gateway_port
  to_port                      = local.metrics_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "gateway_all" {
  security_group_id = aws_security_group.gateway.id
  description       = "LLM providers, IDP JWKS, remote MCP servers, AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "Aurora PostgreSQL, reachable only from the gateway nodes"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-database" }
}

resource "aws_vpc_security_group_ingress_rule" "database_postgres" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from the gateway nodes"
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "ElastiCache for the global rate limit counters"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name}-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_gateway" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Valkey from the rate limit service on each gateway node"
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

data "aws_route53_zone" "selected" {
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "gateway" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
