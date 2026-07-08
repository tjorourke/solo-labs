#!/usr/bin/env bash
# reset.sh — reset the two replicas to their starting metrics (pool-a COLD,
# pool-b HOT) without tearing the cluster down. Use between demo runs.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/set-kv.sh" a 0.10 0 1
"$HERE/set-kv.sh" b 0.90 8 5
echo "reset: pool-a COLD (0.10), pool-b HOT (0.90)"
