#!/usr/bin/env bash
# The lab's headline result: the same load, the gateway's own balancer against the
# Endpoint Picker.
#
#   ./scripts/test.sh              the skew scenario, which is the one that holds
#   ./scripts/test.sh mixed
#   ./scripts/test.sh prefix       see the warning below before believing it
#
# Each run is the identical prompt set at the identical concurrency. The only thing that
# changes between them is which backend the route points at and, for the pool runs,
# which scorers the Endpoint Picker is configured with.
#
# WHAT THIS DOES AND DOES NOT SHOW.
#
# The skew scenario is the one that survived scrutiny. Background load is sent directly
# to one replica, bypassing the gateway entirely, and the measured requests then go
# through the gateway. Measured on two g7e.2xlarge: the gateway's own balancer put
# 23-33% of requests onto the visibly saturated replica, and the queue scorer put none
# there, twice in a row. That is the lab.
#
# The prefix scenario is kept because it is useful to run, and its headline number is
# NOT claimed. Under KV cache pressure the pool path roughly doubles prefix hit rate
# against the Service backend, but the random-picker control matches the weighted
# default exactly, which means the gain cannot be attributed to the prefix scorer and
# the cause is not established. Run it, run the control next to it, and draw your own
# conclusion. Do not quote the number as evidence for cache-aware routing.
#
# Read the gateway-side split, not the latency. On two cards the percentiles move for
# all sorts of reasons; "30 requests, none of them to the saturated replica" does not.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

SCENARIO="${1:-skew}"
REQUESTS="${REQUESTS:-48}"
CONCURRENCY="${CONCURRENCY:-12}"

banner() { printf '\n\n' >&2; step "$*"; }

run() {
  local label="$1"
  "$LAB_ROOT/scripts/bench.sh" "$SCENARIO" \
    --requests "$REQUESTS" --concurrency "$CONCURRENCY" --label "$label"
}

banner "1/4  the gateway's own balancer (backendRef: Service, power of two choices)"
"$LAB_ROOT/scripts/route.sh" service
run "round-robin"

banner "2/4  queue depth only (backendRef: InferencePool)"
"$LAB_ROOT/scripts/route.sh" pool
"$LAB_ROOT/scripts/profile.sh" queue-only
run "queue-only"

banner "3/4  no scoring at all: the control"
# If this matches the profiles above on your workload, the honest conclusion is that
# your workload does not need scheduling, not that the lab is broken.
"$LAB_ROOT/scripts/profile.sh" random
run "random-control"

banner "4/4  the shipped default: queue 2, kv-cache 2, prefix 3"
"$LAB_ROOT/scripts/profile.sh" default
run "default"

banner "left on the default profile, routed at the pool"
"$LAB_ROOT/scripts/route.sh" show
