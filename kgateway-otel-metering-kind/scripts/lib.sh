#!/usr/bin/env bash
set -euo pipefail
export CLUSTER="${CLUSTER:-kgw-metering}"
export CTX="kind-${CLUSTER}"
export KGW_VERSION="${KGW_VERSION:-v2.2.0}"                 # OSS kgateway
export COLLECTOR_VERSION="${COLLECTOR_VERSION:-1.0.0-beta.229}"
export OM_URL="${OM_URL:-http://localhost:48888}"          # self-hosted OpenMeter (docker compose)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; export ROOT
step(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
k(){ kubectl --context "$CTX" "$@"; }
