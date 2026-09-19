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
# The token is minted for you. Turning the gateway on checks ~/.config/agw/token and, if it
# is missing or has expired, re-runs the lab's ./scripts/01-identity.sh and writes the
# employee's token there. The signing key is kept when it already exists, so a re-mint still
# verifies against the JWKS the gateway holds and nothing in the cluster has to change.
#
#   ./scripts/agw-toggle.sh --install         copy this to ~/Downloads for quick flipping
#   ./scripts/agw-toggle.sh --setup-desktop   what to type into Desktop, once
#   ./scripts/agw-toggle.sh --seed-desktop    write Desktop's config instead of typing it
#
# Desktop normally needs one pass through its own developer-mode panel before this script can
# flip it, which is Anthropic's recommended order: configure one machine, then automate.
# --seed-desktop skips the typing by writing the file itself. See
# https://agentgateway.dev/docs/standalone/latest/integrations/llm/clients/claude-desktop/
set -euo pipefail

HOST="${AGW_HOST:-agw.awslab.masterthemesh.com}"
TOKEN_FILE="${AGW_TOKEN_FILE:-$HOME/.config/agw/token}"
# Where the lab lives, so a copy of this file sitting in ~/Downloads can still mint. The
# scripts it calls are 01-identity.sh (the signing key and the four tokens) and
# 11-claude-desktop.sh (the preflight).
LAB_DIR="${LAB_DIR:-$HOME/code/solo/solo-demos/agentgateway-inference-task-routing-eks}"
SUBJECT="${AGW_SUBJECT:-bob}"
DESKTOP_MODEL="${AGW_DESKTOP_MODEL:-claude-sonnet-5}"
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

token_exp() {  # seconds since epoch, or 0
  [ -s "$TOKEN_FILE" ] || { echo 0; return; }
  python3 - "$TOKEN_FILE" <<'PY'
import base64, json, sys
try:
    p = open(sys.argv[1]).read().strip().split(".")[1]
    p += "=" * (-len(p) % 4)
    print(json.loads(base64.urlsafe_b64decode(p)).get("exp", 0))
except Exception:
    print(0)
PY
}

# Mint, rather than telling you to go and mint. 01-identity.sh keeps an existing signing key
# and only re-issues the tokens, so a fresh one still verifies against the JWKS the gateway
# already holds and nothing in the cluster has to be reapplied.
ensure_token() {
  local exp now; exp="$(token_exp)"; now="$(date +%s)"
  if [ -s "$TOKEN_FILE" ] && { [ "${exp:-0}" -eq 0 ] || [ "$exp" -gt "$now" ]; }; then
    [ "${exp:-0}" -gt 0 ] && echo "  token valid to $(date -r "$exp" '+%Y-%m-%d')"
    return 0
  fi
  if [ -s "$TOKEN_FILE" ]; then
    echo "  token expired on $(date -r "$exp" '+%Y-%m-%d'), minting a fresh one"
  else
    echo "  no token yet, minting one"
  fi
  if [ ! -x "$LAB_DIR/scripts/01-identity.sh" ]; then
    echo "  ! cannot mint: no lab at $LAB_DIR"
    echo "    set LAB_DIR=/path/to/agentgateway-inference-task-routing-eks"
    return 1
  fi
  ( cd "$LAB_DIR" && ./scripts/01-identity.sh ) >/dev/null 2>&1 || {
    echo "  ! ./scripts/01-identity.sh failed; run it by hand in $LAB_DIR"; return 1; }
  local var tok
  var="$(echo "$SUBJECT" | tr '[:lower:]' '[:upper:]')_TOKEN"
  # shellcheck disable=SC1090
  tok="$( . "$LAB_DIR/identity/tokens.env"; echo "${!var:-}" )"
  [ -n "$tok" ] || { echo "  ! no token for '$SUBJECT' (have: bob, alice, dave)"; return 1; }
  mkdir -p "$(dirname "$TOKEN_FILE")"
  printf '%s' "$tok" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  echo "  minted a token for $SUBJECT, valid 30 days, at $TOKEN_FILE"
}

preflight() {
  local problems=0
  ensure_token || return 1

  # 60s, not 15. The backends pin max_tokens rather than capping it, so even a tiny
  # request gets a full-length answer and a non-streaming call can sit for twenty seconds
  # before the first byte. A short timeout here reports "the gateway did not answer" for a
  # gateway that is answering perfectly well.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
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

install_copy() {
  local dest="${AGW_INSTALL_DEST:-$HOME/Downloads/agw-toggle.sh}"
  local src; src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  # LAB_DIR is baked into the copy so it keeps working away from the repository. The lab is
  # still the source of truth: re-run --install after changing it rather than editing there.
  sed "s|^LAB_DIR=.*|LAB_DIR=\"\${LAB_DIR:-$LAB_DIR}\"|" "$src" > "$dest"
  chmod +x "$dest"
  cat <<EOF
Copied to $dest

  $dest on        both clients to the gateway
  $dest off       both back to Anthropic
  $dest status    which each one is on

It mints the token itself when there is not a valid one, using
  $LAB_DIR/scripts/01-identity.sh
Re-run this from the lab after changing the script; the copy is a copy.
EOF
}

seed_desktop() {
  # The file-driven route, and the one an enterprise actually uses. Claude Desktop reads a
  # managed configuration at startup, before it decides whether it is talking to Anthropic
  # or to a gateway: the log line is main_pre_managed_config_read_ms. That file is
  # /Library/Managed Preferences/com.anthropic.claudefordesktop.plist, which is what Jamf,
  # Intune or Workspace ONE push, and settings delivered that way cannot be overridden by
  # the user.
  #
  # ~/Library/Application Support/Claude-3p/claude_desktop_config.json is not the input. The
  # app writes it once it is already in third-party mode, so seeding it by hand does nothing:
  # a 1p app never looks in the 3p directory. Measured 2026-09-19 on Claude 2.2553.1, by
  # writing it, restarting, and watching the app sign in to Anthropic regardless.
  #
  # Root-owned on purpose. Run with sudo, or take the command this prints.
  ensure_token || return 1
  local tmp="${TMPDIR:-/tmp}/com.anthropic.claudefordesktop.plist"
  python3 - "$tmp" "$BASE_URL" "$(cat "$TOKEN_FILE")" "$DESKTOP_MODEL" <<'PY'
import plistlib, sys
path, base_url, token, model = sys.argv[1:5]
# Every value a string, including the booleans and the nested JSON: that is what the
# managed-settings reader expects on macOS and Windows.
payload = {
    "inferenceProvider": "gateway",
    "inferenceGatewayBaseUrl": base_url,
    "inferenceCredentialKind": "apiKey",
    "inferenceGatewayAuthScheme": "bearer",
    "inferenceGatewayApiKey": token,
    "inferenceModels": '["%s"]' % model,
    "modelDiscoveryEnabled": "false",
}
with open(path, "wb") as f:
    plistlib.dump(payload, f)
PY
  local dest="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
  if sudo -n true 2>/dev/null; then
    sudo install -m 644 -o root -g wheel "$tmp" "$dest" && echo "  installed $dest"
  else
    cat <<EOF

Built the managed profile at
  $tmp

It needs root, because a managed setting is one the user cannot override. Run:

  sudo install -m 644 -o root -g wheel "$tmp" "$dest"

then quit Claude Desktop fully (Cmd+Q) and reopen it.
EOF
    return 0
  fi
  echo "  quit Claude Desktop fully (Cmd+Q) and reopen it"
}

unseed_desktop() {
  local dest="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
  if sudo -n true 2>/dev/null; then
    sudo rm -f "$dest" && echo "  removed $dest"
  else
    echo "Run:  sudo rm -f \"$dest\""
  fi
  echo "  quit Claude Desktop fully (Cmd+Q) and reopen it"
}

case "${1:-}" in
  on)      apply on ;;
  off)     apply off ;;
  toggle)  if [ "$(code_state)" = on ]; then apply off; else apply on; fi ;;
  status)  show; if [ "$(code_state)" = on ]; then preflight || true; fi ;;
  --setup-desktop|setup-desktop) desktop_setup_help ;;
  --seed-desktop|seed-desktop)   seed_desktop ;;
  --unseed-desktop)              unseed_desktop ;;
  --install|install)             install_copy ;;
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
  *) echo "usage: $(basename "$0") [on|off|toggle|status|--setup-desktop|--seed-desktop|--install]" >&2; exit 2 ;;
esac
