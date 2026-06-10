#!/usr/bin/env bash
# ask.sh — ask the OpenClaw SRE sandbox to do something, from your laptop. Thin
# wrapper around the in-sandbox `sre-agent` helper (installed by
# 05-equip-sandbox.sh). Streams OpenClaw's reasoning + actions back to your tty.
#
# Three ways to pass the prompt (use whichever is comfortable):
#
#   # 1. one-line argument (mind the shell quoting)
#   ./scripts/ask.sh "find the failing deployment, fix it, and confirm it recovered"
#
#   # 2. multi-line via a here-doc (no quoting headaches)
#   ./scripts/ask.sh <<'EOF'
#   Triage every namespace for broken workloads.
#   Fix what you are permitted to; escalate the rest to Slack.
#   EOF
#
#   # 3. pipe it in
#   echo "what is broken in the cluster?" | ./scripts/ask.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Prompt precedence: command-line args win; otherwise read stdin (here-doc /
# pipe); otherwise a sensible default. Newlines in the prompt are fine — they
# are collapsed to spaces so the whole thing reaches OpenClaw as one message.
if [[ "$#" -gt 0 ]]; then
  PROMPT="$*"
elif [[ ! -t 0 ]]; then
  PROMPT="$(cat)"
else
  PROMPT="what is broken in the cluster?"
fi
PROMPT="$(printf '%s' "$PROMPT" | tr '\n' ' ' | sed 's/  */ /g')"
[[ -n "${PROMPT// /}" ]] || die "empty prompt"

read -r SB_NS SB_POD SB_SA < <(find_sandbox || true)
[[ -n "${SB_POD:-}" ]] || die "sandbox not found — bring the lab up first (./scripts/quick.sh up)"

step "Asking OpenClaw (${SB_NS}/${SB_POD})"
log "prompt: $PROMPT"
echo "" >&2
# Note: exec'ing kubectl directly (kc is a shell function, which exec can't run).
exec kubectl --context "$CTX" -n "$SB_NS" exec -it "$SB_POD" -c agent -- su sandbox -c "sre-agent \"$PROMPT\""
