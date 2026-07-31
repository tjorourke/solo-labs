# ---------------------------------------------------------------------------
# ElastiCache for Valkey, holding the global rate limit counters.
#
# This is the piece that makes a rate limit mean what it says across three nodes.
# agentgateway's localRateLimit is per process, so a limit of 10 per minute set on
# three nodes lets roughly 30 through. policies.remoteRateLimit speaks the Envoy
# ratelimit protocol to a service that keeps its counters in Redis, so with one
# shared cluster the limit is 10 for the whole fleet.
#
# The ratelimit service itself runs as a local unit on each gateway node rather than
# on its own instance: that keeps the hop off the network, and there is no shared
# state in the service to lose, only in Valkey.
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "Global rate limit counters for the ${local.name} agentgateway fleet"

  engine         = "valkey"
  engine_version = "8.0"
  node_type      = var.redis_node_type
  port           = 6379

  num_cache_clusters = var.redis_node_count

  # A single node cannot be multi-AZ, and there is nothing to fail over to.
  automatic_failover_enabled = var.redis_node_count > 1
  multi_az_enabled           = var.redis_node_count > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  # The Envoy ratelimit service does not speak TLS to Redis without extra
  # configuration, and this cluster is only reachable from the gateway security
  # group inside private subnets.
  transit_encryption_enabled = false
  at_rest_encryption_enabled = true

  apply_immediately = true

  # Counters are ephemeral by definition; losing them on a restart just resets the
  # window. Snapshots would be waste.
  snapshot_retention_limit = 0
}
