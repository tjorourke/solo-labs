# ---------------------------------------------------------------------------
# The fleet: three EC2 instances, one per AZ, each running agentgateway as a plain
# systemd service. No container for the gateway, no orchestrator, no controller.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "gateway" {
  name_prefix = "${local.name}-"

  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type

  # No key_name on purpose. Shell access is SSM Session Manager only, and the
  # security group has no port 22 rule to go with a key even if one were set.

  iam_instance_profile {
    arn = aws_iam_instance_profile.gateway.arn
  }

  vpc_security_group_ids = [aws_security_group.gateway.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # base64gzip, not base64encode. EC2 caps user data at 16 KB and this bootstrap is
  # about 17 KB of shell, which base64 inflates to roughly 22 KB. cloud-init detects
  # and decompresses gzipped user data, which brings it down to under 8 KB.
  # The tradeoff is that the user data is no longer readable in the console; read the
  # rendered copy on a node at /var/log/agw-bootstrap.log instead.
  user_data = base64gzip(templatefile("${path.module}/user_data.sh.tftpl", {
    region               = var.aws_region
    agentgateway_version = var.agentgateway_version
    ratelimit_image      = var.ratelimit_image
    config_bucket        = aws_s3_bucket.config.id
    runtime_secret_arn   = aws_secretsmanager_secret.runtime.arn
    log_group            = aws_cloudwatch_log_group.gateway.name
    metrics_namespace    = local.metrics_namespace
    redis_host           = aws_elasticache_replication_group.this.primary_endpoint_address
    ratelimit_port       = local.ratelimit_port
    metrics_port         = local.metrics_port
    readiness_port       = local.readiness_port
    otlp_port            = 4317
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-gateway" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-gateway" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "gateway" {
  name = local.name

  min_size         = var.fleet_size
  max_size         = var.fleet_size
  desired_capacity = var.fleet_size

  # One subnet per AZ, so the group spreads the three nodes across three AZs and
  # rebuilds a terminated node in the AZ that lost it.
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.gateway.id
    version = aws_launch_template.gateway.latest_version
  }

  target_group_arns = [aws_lb_target_group.gateway.arn]

  health_check_type = "ELB"

  # The bootstrap installs the binary, pulls the config from S3 and reads the secret
  # before it can pass the readiness check. Give it room so the group does not decide
  # a healthy node is unhealthy while it is still coming up.
  health_check_grace_period = 300

  # Prove the AZ spread rather than hoping for it.
  availability_zone_distribution {
    capacity_distribution_strategy = "balanced-best-effort"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      # Two of three stay in service through a refresh, so a version bump or a
      # launch template change is a rolling upgrade rather than an outage.
      min_healthy_percentage = 66
      instance_warmup        = 300
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-gateway"
    propagate_at_launch = true
  }

  tag {
    key                 = "Lab"
    value               = "agentgateway-standalone-aws-ha"
    propagate_at_launch = true
  }

  timeouts {
    delete = "20m"
  }

  depends_on = [
    aws_s3_object.config,
    aws_s3_object.model_costs,
    aws_s3_object.echo_openapi,
    aws_s3_object.ratelimit_config,
    aws_secretsmanager_secret_version.runtime,
    aws_rds_cluster_instance.writer,
    aws_elasticache_replication_group.this,
  ]
}
