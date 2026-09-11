# ---------------------------------------------------------------------------
# Application Load Balancer across three AZs.
#
# ALB rather than NLB because it terminates TLS with an ACM certificate and still
# carries everything the gateway serves: server-sent events for LLM streaming,
# streamable HTTP for MCP, and gRPC for A2A.
#
# There is no session stickiness on the target group, and that is deliberate. MCP
# session state is encrypted into the Mcp-Session-Id itself with the fleet-wide
# session key, so any node can pick up a session any other node issued. Turning on
# stickiness would hide the most interesting property of the deployment.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.selected.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false

  subnets         = aws_subnet.public[*].id
  security_groups = [aws_security_group.alb.id]

  # The default 60 seconds cuts long completions off mid-stream. Streaming chat
  # completions and long-lived MCP sessions both need more room than that.
  idle_timeout = 300

  enable_http2               = true
  drop_invalid_header_fields = true

  # The teardown script has to be able to remove this without a manual step.
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "gateway" {
  name     = "${local.name}-gw"
  port     = local.gateway_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  target_type = "instance"

  # The readiness endpoint, not the data port. It reports whether the config loaded
  # and the listeners are bound, so a node that came up but failed to parse the
  # config never receives traffic.
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = tostring(local.readiness_port)
    path                = "/healthz/ready"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Long enough for in-flight completions to finish when a node is being replaced,
  # short enough that the node-loss demo does not become a coffee break.
  deregistration_delay = 30

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
