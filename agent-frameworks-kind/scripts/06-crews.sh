#!/usr/bin/env bash
# 06-crews.sh — build the BYO crew images and apply every crew.
#
# Builds an image for each src/sre-crew-* that has a Dockerfile, loads it into
# kind, then applies all agent manifests in yaml/agents/ (the kagent-native team
# has no image). Re-runnable: only present crews are built, and kubectl apply +
# kind load are idempotent. Waits for every Agent to report Ready.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Building + loading BYO crew images"
built=0
for dir in "$LAB_ROOT"/src/sre-crew-*; do
  [[ -f "$dir/Dockerfile" ]] || continue
  build_and_load "$dir" "$(basename "$dir"):dev"
  built=$((built+1))
done
[[ $built -gt 0 ]] && ok "built $built crew image(s)" || warn "no crew images found under src/sre-crew-*"

step "Applying crews (kagent-native team + BYO crews)"
kc apply -f "$LAB_ROOT/yaml/agents/" >/dev/null
ok "agents applied"

step "Waiting for every Agent to be Ready"
for a in $(kc -n kagent get agent -o name 2>/dev/null | cut -d/ -f2); do
  wait_agent "$a" 300 && ok "$a Ready" || warn "$a not Ready in 5m"
done
kc -n kagent get agent 2>/dev/null | sed 's/^/  /' >&2 || true

step "Crews ready"
echo "  Ask a crew (as Alice):  AGENT=sre-crew-langgraph ./scripts/ask.sh \"the checkout service is down - investigate and fix it\"" >&2
echo "  Next: ./scripts/07-augment.sh" >&2
