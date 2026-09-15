#!/usr/bin/env bash
# The platform on an existing cluster: agentgateway, the device plugin, the models.
#
#   ./scripts/platform/up.sh
#
# Each step is skipped where it is already done, so this is safe to re-run. The flow steps
# (scripts/01 to 05) go on top. vLLM Semantic Router and OPA are installed by the flow steps,
# because their configuration is the flow.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
banner() { echo; echo "############ $*"; }
banner "1/3  agentgateway";   "$HERE/scripts/platform/10-agentgateway.sh"
banner "2/3  device plugin";  "$HERE/scripts/platform/20-device-plugin.sh"
banner "3/3  models";         "$HERE/scripts/platform/30-models.sh"
