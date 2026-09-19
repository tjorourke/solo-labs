#!/usr/bin/env bash
# Flip Claude Code and Claude Desktop between your agentgateway and Anthropic direct.
#
#   ./scripts/agw-toggle.sh on        send both to the gateway
#   ./scripts/agw-toggle.sh off       back to normal
#   ./scripts/agw-toggle.sh status    say which each one is on, and check the gateway
#   ./scripts/agw-toggle.sh           show the state and ask
#
# Two clients, two config surfaces, and nothing shared between them. Conflating them is
# the mistake this script exists to stop:
#
#   Claude Code      ~/.claude/settings.json          env.ANTHROPIC_BASE_URL + apiKeyHelper
#   Claude Desktop   ~/Library/Application Support/Claude-3p/claude_desktop_config.json
#                                                     deploymentMode: "3p" | "1p"
#
# Restart both after flipping. Each reads its settings at launch, so a session already
# open keeps whatever it started with. Desktop needs a full quit (Cmd+Q); closing the
# window is not enough.
#
# Desktop needs one manual setup before this script can toggle it, and that is Anthropic's
# own recommended order: configure one machine in developer mode, then automate. See
# --setup-desktop below, or
# https://agentgateway.dev/docs/standalone/latest/integrations/llm/clients/claude-desktop/
set -euo pipefail

HOST="${AGW_HOST:-agw.awslab.masterthemesh.com}"
TOKEN_FILE="${AGW_TOKEN_FILE:-$HOME/.config/agw/token}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DESKTOP_CFG="${CLAUDE_DESKTOP_3P_CONFIG:-$HOME/Library/Application Support/Claude-3p/claude_desktop_config.json}"
BASE_URL="https://$HOST"

c_on="$(printf '\033[32m')"; c_off="$(printf '\033[33m')"; c_dim="$(printf '\033[2m')"; c_r="$(printf '\033[0m')"
[ -t 1 ] || { c_on=""; c_off=""; c_dim=""; c_r=""; }

# ---------------------------------------------------------------- Claude Code

code_state() {  # -> on | off
  [ -f "$SETTINGS" ] || { echo off; return; }
  python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("off"); raise SystemExit
print("on" if d.get("env", {}).get("ANTHROPIC_BASE_URL") else "off")
PY
}

code_edit() {  # code_edit on|off
  [ -f "$SETTINGS" ] && { [ -f "$SETTINGS.pre-agw" ] || cp "$SETTINGS" "$SETTINGS.pre-agw"; \
    cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"; }
  python3 - "$SETTINGS" "$1" "$BASE_URL" "$TOKEN_FILE" <<'PY'
import json, os, sys
path, mode, base_url, token_file = sys.argv[1:5]
d = json.load(open(path)) if os.path.exists(path) else {}
env = d.setdefault("env", {})
if mode == "on":
    env["ANTHROPIC_BASE_URL"] = base_url
    # An older version of this script set CLAUDE_CODE_SIMPLE. In minimal mode apiKeyHelper
    # is only read from --settings or a project .claude/settings.json, never from this
    # file, so the session starts with no credential and loops on "Not logged in".
    env.pop("CLAUDE_CODE_SIMPLE", None)
    d["apiKeyHelper"] = f"cat {token_file}"
else:
    env.pop("ANTHROPIC_BASE_URL", None)
    env.pop("CLAUDE_CODE_SIMPLE", None)
    d.pop("apiKeyHelper", None)
    if not env:
        d.pop("env", None)
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
}

# ------------------------------------------------------------- Claude Desktop

desktop_state() {  # -> on | off | unconfigured
  [ -f "$DESKTOP_CFG" ] || { echo unconfigured; return; }
  python3 - "$DESKTOP_CFG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unconfigured"); raise SystemExit
# The gateway details live in this file once developer mode has written them. Without a
# base URL there is nothing to switch to, so treat it as never set up rather than off.
has_gw = bool(d.get("inferenceGatewayBaseUrl") or (d.get("gateway") or {}).get("baseUrl"))
print(("on" if d.get("deploymentMode") == "3p" else "off") if has_gw else "unconfigured")
PY
}

desktop_edit() {  # desktop_edit on|off
  python3 - "$DESKTOP_CFG" "$1" <<'PY'
import json, os, sys
path, mode = sys.argv[1:3]
d = json.load(open(path))
d["deploymentMode"] = "3p" if mode == "on" else "1p"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
}

desktop_setup_help() {
  cat <<EOF

Claude Desktop has not been pointed at a gateway yet, so there is nothing to toggle.
Do this once, by hand, and the script can flip it from then on:

  1. Help > Troubleshooting > Enable Developer Mode, then quit fully (Cmd+Q) and reopen
  2. Developer > Configure Third Party Inference > Gateway
  3. Gateway base URL   $BASE_URL
     Credential kind    Static API key, auth scheme Bearer
     Token              $(cat "$TOKEN_FILE" 2>/dev/null || echo '<run ./scripts/01-identity.sh>')
     Models             claude-sonnet-5        (a full model ID, not an alias)
     Model discovery    off
  4. Test connection, Apply Changes, then quit fully and reopen

Anthropic recommends that order too: set one machine up in developer mode, then automate
or export it. Full field reference, including OIDC sign-in and MDM rollout:
https://agentgateway.dev/docs/standalone/latest/integrations/llm/clients/claude-desktop/

./scripts/11-claude-desktop.sh checks the gateway can serve Desktop before you start.
EOF
}

# -------------------------------------------------------------------- shared

preflight() {
  local problems=0
  if [ ! -s "$TOKEN_FILE" ]; then
    echo "  ! no token at $TOKEN_FILE"
    echo "    run the lab's ./scripts/01-identity.sh, or point AGW_TOKEN_FILE at one"
    return 1
  fi
  local exp now
  exp="$(python3 - "$TOKEN_FILE" <<'PY'
import base64, json, sys
try:
    p = open(sys.argv[1]).read().strip().split(".")[1]
    p += "=" * (-len(p) % 4)
    print(json.loads(base64.urlsafe_b64decode(p)).get("exp", 0))
except Exception:
    print(0)
PY
)"
  now="$(date +%s)"
  if [ "${exp:-0}" -gt 0 ] && [ "$exp" -lt "$now" ]; then
    echo "  ! the token expired on $(date -r "$exp" '+%Y-%m-%d'); mint a fresh one with ./scripts/01-identity.sh"
    return 1
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -X POST "$BASE_URL/v1/messages" \
      -H "Authorization: Bearer $(cat "$TOKEN_FILE" 2>/dev/null)" \
      -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)"
  case "${code:-000}" in
    200) echo "  gateway answered 200" ;;
    000) echo "  ! $HOST did not answer. Is the cluster up, and the GPU nodegroup back?"; problems=1 ;;
    401|403) echo "  ! gateway refused the token ($code). Wrong token, or OPA denies this user."; problems=1 ;;
    429) echo "  ! gateway is rate limiting or the budget is spent ($code)."; problems=1 ;;
    *)   echo "  ! gateway returned $code"; problems=1 ;;
  esac
  return $problems
}

show() {
  local c d; c="$(code_state)"; d="$(desktop_state)"
  if [ "$c" = on ]; then
    echo "Claude Code     ${c_on}ON the gateway${c_r}   -> $BASE_URL"
  else
    echo "Claude Code     ${c_off}OFF${c_r}              -> Anthropic direct"
  fi
  case "$d" in
    on)  echo "Claude Desktop  ${c_on}ON the gateway${c_r}   -> its configured gateway" ;;
    off) echo "Claude Desktop  ${c_off}OFF${c_r}              -> Anthropic direct" ;;
    *)   echo "Claude Desktop  ${c_dim}not set up${c_r}       -> run with --setup-desktop" ;;
  esac
  [ "$c" = on ] && echo "${c_dim}  token: $TOKEN_FILE${c_r}"
  return 0
}

apply() {  # apply on|off
  local want="$1"
  if [ "$want" = on ]; then
    echo "Checking the gateway before sending your sessions to it:"
    preflight || { echo; echo "Not flipping. Fix the above and run again."; return 1; }
    echo
  fi

  [ "$(code_state)" = "$want" ] && echo "Claude Code already $want." || code_edit "$want"

  case "$(desktop_state)" in
    unconfigured) echo "Claude Desktop skipped: never pointed at a gateway. --setup-desktop explains it." ;;
    "$want")      echo "Claude Desktop already $want." ;;
    *)            desktop_edit "$want" ;;
  esac

  echo; show; echo
  echo "Restart both for this to take effect. Claude Desktop needs a full quit (Cmd+Q):"
  echo "closing the window leaves it running with the old setting."
  [ "$want" = on ] && cat <<EOF

Try these two and watch where they land:
  "Review the settle() method in com.example.internal settlement-service"  -> your GPU
  "Explain what a Python list comprehension is"                            -> Anthropic
EOF
  return 0
}

case "${1:-}" in
  on)      apply on ;;
  off)     apply off ;;
  toggle)  if [ "$(code_state)" = on ]; then apply off; else apply on; fi ;;
  status)  show; if [ "$(code_state)" = on ]; then preflight || true; fi ;;
  --setup-desktop|setup-desktop) desktop_setup_help ;;
  ""|prompt)
    show; echo
    if [ "$(code_state)" = on ]; then
      printf 'Turn the gateway OFF and go back to Anthropic direct? [y/N] '
    else
      printf 'Turn the gateway ON and send Claude to %s? [y/N] ' "$HOST"
    fi
    read -r reply
    case "$reply" in
      [yY]*) if [ "$(code_state)" = on ]; then apply off; else apply on; fi ;;
      *) echo "Left as it is." ;;
    esac
    ;;
  *) echo "usage: $(basename "$0") [on|off|toggle|status|--setup-desktop]" >&2; exit 2 ;;
esac
