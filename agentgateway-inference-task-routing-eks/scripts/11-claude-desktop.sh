#!/usr/bin/env bash
# Claude Desktop against the gateway: the settings to type, and a preflight that fails
# here rather than in front of a customer.
#
#   ./scripts/11-claude-desktop.sh            settings for bob, then check the gateway
#   ./scripts/11-claude-desktop.sh alice      the same for a different employee
#
# Claude Desktop is not Claude Code and shares none of its configuration. It never reads
# ~/.claude/settings.json, so the toggle script that points Claude Code at a gateway does
# nothing here, and a machine can have Claude Code on the gateway and Desktop on
# Anthropic at the same time. Desktop has its own setting, under developer mode.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUB="${1:-bob}"
HOST="${HOST:-agw.awslab.masterthemesh.com}"
BASE="https://$HOST"

[ -f "$HERE/identity/tokens.env" ] || { echo "no identity/tokens.env; run ./scripts/01-identity.sh first" >&2; exit 1; }
. "$HERE/identity/tokens.env"
VAR="$(echo "$SUB" | tr '[:lower:]' '[:upper:]')_TOKEN"
TOKEN="${!VAR:-}"
[ -n "$TOKEN" ] || { echo "no token for '$SUB' (have: bob, alice, dave)" >&2; exit 1; }

green() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn()  { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

cat <<EOF

Claude Desktop, Settings, then:

  Help > Troubleshooting > Enable Developer Mode
  Developer > Configure Third Party Inference > Gateway

  Gateway base URL   $BASE
  Credential         Bearer token   <- not "API key"
  Token              the value printed below
  Models             claude-sonnet-5

EOF

echo "  Token for $SUB:"
echo "    $TOKEN"
echo

echo "Preflight, the same calls Desktop will make:"
problems=0

# 1. Bearer, not API key. Desktop sends an API key as X-Api-Key, which carries no bearer
#    token, so the gateway's JWT policy refuses it. Worth proving both ways round: the
#    failure is a 502 rather than a 401, because the refusal is plain text and the
#    Messages path cannot translate it, and that sends people looking at the model.
body='{"model":"claude-sonnet-5","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$BASE/v1/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' -d "$body" || true)"
[ "$code" = 200 ] && green "POST /v1/messages with a bearer token: 200" \
  || { bad "POST /v1/messages returned $code with a bearer token"; problems=1; }

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$BASE/v1/messages" \
  -H "X-Api-Key: $TOKEN" -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' -d "$body" || true)"
[ "$code" = 200 ] && warn "X-Api-Key also works; either credential kind will do" \
  || green "X-Api-Key alone is refused ($code), so pick Bearer token in the dialog"

# 2. Desktop lists models at startup and reports "no models" when this fails.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/v1/models" \
  -H "Authorization: Bearer $TOKEN" || true)"
[ "$code" = 200 ] && green "GET /v1/models: 200" \
  || { bad "GET /v1/models returned $code"; problems=1; }

# 3. Streaming. Desktop streams every reply, and a gateway that answers the non-streaming
#    call and breaks on SSE looks like the model hanging.
first="$(curl -s --max-time 45 -N -X POST "$BASE/v1/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5","max_tokens":24,"stream":true,"messages":[{"role":"user","content":"count to three"}]}' \
  2>/dev/null | head -1 || true)"
case "$first" in
  event:*) green "streaming replies arrive as SSE" ;;
  *)       bad "streaming did not start (first line: ${first:-empty})"; problems=1 ;;
esac

# 4. HTTPS. Desktop refuses a plain HTTP base URL on anything but loopback, so a
#    port-forward cannot serve it and neither can a self-signed certificate.
case "$BASE" in
  https://*) green "base URL is HTTPS" ;;
  *) bad "Desktop refuses a plain HTTP base URL off loopback"; problems=1 ;;
esac

# 5. The budget. A frontier budget sized for curl is spent by one Desktop conversation,
#    and over the limit the refusal reaches Desktop as a 502 it will retry.
KCTX="${KUBE_CONTEXT:-}"
kc() { if [ -n "$KCTX" ]; then kubectl --context="$KCTX" "$@"; else kubectl "$@"; fi; }
if command -v kubectl >/dev/null; then
  lim="$(kc -n agentgateway-system get enterpriseagentgatewaybudget frontier-budgets \
        -o jsonpath='{.spec.budgets[0].limit.amount}' 2>/dev/null || true)"
  if [ -z "$lim" ]; then
    # Silently skipping this is how you find out mid-demo. kubectl is usually pointed at
    # another cluster; the gateway calls above went over the internet and do not care.
    warn "could not read the frontier budget (kubectl context is '$(kubectl config current-context 2>/dev/null || echo none)'). Set KUBE_CONTEXT= to check it."
  elif [ "$lim" -lt 200000 ]; then
    warn "frontier budget is $lim tokens/day; one Desktop conversation will exhaust it and the refusal reaches Desktop as a 502 it retries. Raise it, or demonstrate the refusal on purpose."
  else
    green "frontier budget is $lim tokens/day, enough for a conversation"
  fi
fi

echo
if [ "$problems" -eq 0 ]; then
  cat <<EOF
Ready. Quit Claude Desktop fully and reopen it: the gateway setting is read once, at
launch, so a running app keeps whatever it started with.

Then ask it these two, and watch where they land:

  "Explain what a Python list comprehension is"          -> the frontier, if $SUB may
  "Review this for concurrency bugs: void credit(long a){b+=a;}"
                                                         -> your GPU, whoever asks

./scripts/08-show-decision.sh prints the task, the pool and the reason for a prompt.
EOF
else
  echo "Fix the failures above before demonstrating."
  exit 1
fi
