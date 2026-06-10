#!/usr/bin/env bash
# test.sh — prove the routing decision. Sends category-specific prompts, each
# with "model": "auto", and prints the category + adapter the Semantic Router
# picked. The router surfaces its decision in x-vsr-* response headers
# (x-vsr-selected-category, x-vsr-selected-model), which are authoritative.
#
# A correct run shows DIFFERENT adapters for different categories, e.g.
# math → math-expert, law → law-expert, history → humanities-expert. That
# proves the router rewrote the request body and the gateway forwarded it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PORT="${PORT:-18080}"
BASE="http://localhost:${PORT}"

step "Opening a temporary port-forward on :${PORT}"
# Clear any stale forward left over from a previous run on the same port.
pkill -f "port-forward.*${PORT}:80" 2>/dev/null || true
sleep 1
cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT INT TERM
kc -n agentgateway-system port-forward "svc/vllm-gateway" "${PORT}:80" >/dev/null 2>&1 &
for _ in $(seq 1 20); do
  curl -sS -o /dev/null "${BASE}/" >/dev/null 2>&1 && break
  sleep 1
done

ask() {
  local label="$1" prompt="$2"
  local hdr cat model
  hdr=$(curl -sS -D - -o /dev/null -X POST "${BASE}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":16,\"temperature\":0}" \
    2>/dev/null || true)
  cat=$(printf '%s' "$hdr"   | awk -F': ' 'tolower($1)=="x-vsr-selected-category"{print $2}' | tr -d '\r')
  model=$(printf '%s' "$hdr" | awk -F': ' 'tolower($1)=="x-vsr-selected-model"{print $2}'    | tr -d '\r')
  printf '  %-10s → category=%-12s adapter=%s\n' "$label" "${cat:-<none>}" "${model:-<none>}" >&2
}

step "Sending category prompts (all with \"model\": \"auto\")"
ask "math"     "What is the derivative of x^3?"
ask "law"      "What are the elements of a valid contract?"
ask "biology"  "How do mRNA vaccines trigger an immune response?"
ask "business" "How should a startup price a SaaS product?"
ask "history"  "What caused the fall of the Roman Republic?"

step "Done"
echo "  Distinct adapters per category = the router rewrote the body and the gateway forwarded it." >&2
echo "  Router decision logs: kubectl --context $CTX -n agentgateway-system logs deploy/semantic-router" >&2
