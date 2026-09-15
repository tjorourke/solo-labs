#!/usr/bin/env bash
# The platform, end to end: cluster, agentgateway, device plugin, models.
#
#   ./scripts/platform/up.sh
#
# Each step is skipped where it is already done, so this is safe to re-run on a cluster that
# Part 3 built. The flow steps (scripts/01 to 05) go on top of it. vLLM Semantic Router and
# OPA are installed by the flow steps, because their configuration is the flow.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
banner() { echo; echo "############ $*"; }
banner "1/4  cluster";        "$HERE/scripts/platform/00-cluster.sh"
banner "2/4  agentgateway";   "$HERE/scripts/platform/10-agentgateway.sh"
banner "3/4  device plugin";  "$HERE/scripts/platform/20-device-plugin.sh"
banner "4/4  models";         "$HERE/scripts/platform/30-models.sh"
