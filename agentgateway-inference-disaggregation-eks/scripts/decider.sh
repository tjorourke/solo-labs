#!/usr/bin/env bash
# Set the threshold at which a request is worth disaggregating, and restart the picker.
#
#   ./scripts/decider.sh 16        disaggregate almost everything (llm-d's sample value)
#   ./scripts/decider.sh 999999    disaggregate nothing: monolithic on the decode worker
#
# This is the lab's A/B switch, and it is a good one because it changes ONE number and
# nothing else. Same two pods, same route, same picker, same gateway. The 999999 run is
# not a different deployment, it is the same deployment declining to use the second card,
# which makes it the honest baseline for what disaggregation bought.
#
# The value is nonCachedTokens: how much of the prompt is not already in cache. Below the
# threshold the prompt is cheap enough to prefill locally and shipping KV blocks would
# cost more than it saves.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

N="${1:-}"
[ -n "$N" ] || die "usage: $0 <nonCachedTokens>   (16 = disaggregate almost everything, 999999 = none)"
case "$N" in ''|*[!0-9]*) die "nonCachedTokens must be a whole number, got '$N'" ;; esac

# Rewrite the one value inside the embedded EPP config. The config lives in a ConfigMap
# as a single YAML string, so this edits the file on disk and re-applies rather than
# trying to patch a nested document in place.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s/^\( *nonCachedTokens: \).*/\1$N/" "$LAB_ROOT/yaml/10-epp.yaml" > "$tmp"
grep -q "nonCachedTokens: $N" "$tmp" || die "failed to set nonCachedTokens — has yaml/10-epp.yaml changed shape?"
kc apply -f "$tmp" >/dev/null

# A ConfigMap change does not restart anything, and the mounted file can take up to a
# minute to update anyway. Roll the pod so the new value is definitely in force before
# the next measurement, and so the prefix index starts empty for both runs.
kc -n "$NS" rollout restart deploy/pd-epp >/dev/null
kc -n "$NS" rollout status  deploy/pd-epp --timeout=180s >/dev/null
ok "nonCachedTokens = $N, picker restarted with an empty prefix index"
