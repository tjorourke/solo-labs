#!/usr/bin/env bash
# Point Claude Code at the gateway, for one directory rather than for the whole machine.
#
#   ./scripts/10-claude-code.sh                      set it up for ./claude-code-demo as bob
#   ./scripts/10-claude-code.sh ~/work/bank alice     a different directory, a different employee
#
# Claude Code posts the Anthropic Messages API. The gateway takes /v1/messages through the
# same two hops as an editor's /v1/chat/completions: the router classifies the prompt, OPA
# decides the pool and the class, and the decision route picks the model. The only extra
# piece is the translation on the GPU backends, which is in yaml/40-backends.yaml.
#
# This writes PROJECT settings, not `~/.claude/settings.json`. Setting it globally sends
# every Claude Code session on the machine to this gateway, including whatever you are in
# the middle of, and the private models cannot drive Claude Code. Keep it to one directory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh" 2>/dev/null || true

DIR="${1:-$HERE/claude-code-demo}"
SUB="${2:-bob}"
HOST="${HOST:-agw.awslab.masterthemesh.com}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/agw/token}"
[ -f "$HERE/identity/tokens.env" ] || { echo "no identity/tokens.env; run ./scripts/01-identity.sh first" >&2; exit 1; }

# The token is the employee's identity, minted by 01-identity.sh alongside the JWKS the
# gateway already holds. OPA reads the subject out of it to decide which pools that person
# may use: bob gets both, alice is private only, dave is frontier only.
. "$HERE/identity/tokens.env"
VAR="$(echo "$SUB" | tr '[:lower:]' '[:upper:]')_TOKEN"
TOKEN="${!VAR:-}"
[ -n "$TOKEN" ] || { echo "no token for '$SUB' in identity/tokens.env (have: bob, alice, dave)" >&2; exit 1; }
mkdir -p "$(dirname "$TOKEN_FILE")"
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

mkdir -p "$DIR/.claude"
cat > "$DIR/.claude/settings.json" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://$HOST",
    "CLAUDE_CODE_SIMPLE": "1"
  },
  "apiKeyHelper": "cat $TOKEN_FILE"
}
EOF

cat <<EOF

Claude Code is wired for $DIR as $SUB.

  cd $DIR && claude

  ANTHROPIC_BASE_URL  https://$HOST
  apiKeyHelper        cat $TOKEN_FILE   (the employee's token)
  CLAUDE_CODE_SIMPLE  1                 credentials come from apiKeyHelper only

CLAUDE_CODE_SIMPLE matters: without it a Claude subscription login wins over apiKeyHelper
and the traffic never reaches the gateway, which looks like the gateway ignoring you.

Ask it something about this repository's own code and the answer comes off the GPU. Ask it
a general programming question and it goes to the frontier. ./scripts/08-show-decision.sh
prints which, and why.
EOF
