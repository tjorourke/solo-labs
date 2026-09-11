locals {
  metrics_namespace = "agentgateway/${local.name}"
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/agentgateway/${local.name}"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# Alarms that make node loss visible without watching a terminal.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "One or more agentgateway nodes are out of service behind the ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.gateway.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${local.name}-no-healthy-hosts"
  alarm_description   = "No agentgateway node is in service; the fleet is down"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.gateway.arn_suffix
  }
}
