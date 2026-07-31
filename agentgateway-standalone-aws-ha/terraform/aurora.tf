# ---------------------------------------------------------------------------
# Aurora PostgreSQL Serverless v2, writer plus reader across two AZs.
#
# This one cluster does two jobs for the fleet, and both are what let three
# independent binaries behave like one gateway:
#
# 1. config.database.url -- the request log. Every proxied request is written here,
#    so the Analytics page and the cost dashboard in the admin UI show all three
#    nodes' traffic in one view instead of a third of it. The schema is created on
#    first startup; there is no migration step.
#
# 2. config.storage.mode: hybrid -- the config overlay. The file from S3 is the
#    baseline, and anything edited in the admin UI is written here instead of to the
#    local file. agentgateway uses PostgreSQL LISTEN/NOTIFY to tell the other nodes
#    the overlay changed, so a virtual key created on one node is live on the other
#    two without a restart, and a node the Auto Scaling group replaces inherits it.
#
# SQLite is the default backend and is explicitly documented as unsafe for more than
# one instance, so Postgres is not optional here.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = local.name
  family = "aurora-postgresql16"

  # The overlay fan-out is LISTEN/NOTIFY, so each node holds a listener connection
  # open for the lifetime of the process on top of its query pool.
  parameter {
    name         = "max_connections"
    value        = "200"
    apply_method = "pending-reboot"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = local.name

  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = var.aurora_engine_version

  database_name   = "agentgateway"
  master_username = "agentgateway"
  master_password = random_password.database.result

  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  vpc_security_group_ids          = [aws_security_group.database.id]

  storage_encrypted = true

  # A lab, not production: no final snapshot, destroy cleanly.
  skip_final_snapshot     = true
  backup_retention_period = 1
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  enabled_cloudwatch_logs_exports = ["postgresql"]
}

# Writer. Everything the gateway does goes through this endpoint: the request log
# writes, the overlay reads and writes, and the NOTIFY.
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name}-writer"
  cluster_identifier = aws_rds_cluster.this.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.this.engine
  engine_version = aws_rds_cluster.this.engine_version

  availability_zone = local.azs[0]

  promotion_tier      = 0
  apply_immediately   = true
  publicly_accessible = false
}

# Reader in a second AZ. It exists so the AZ-failure demo has something to fail over
# to: killing the writer promotes this one and the fleet reconnects.
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${local.name}-reader"
  cluster_identifier = aws_rds_cluster.this.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.this.engine
  engine_version = aws_rds_cluster.this.engine_version

  availability_zone = local.azs[1]

  promotion_tier      = 1
  apply_immediately   = true
  publicly_accessible = false
}
