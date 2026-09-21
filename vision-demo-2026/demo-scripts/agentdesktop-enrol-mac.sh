#!/usr/bin/env bash
# agentdesktop-enrol-mac.sh — enrol this Mac with the controller and show the
# policy land in Claude Code's own settings file.
#
#   ./demo-scripts/agentdesktop-enrol-mac.sh binary    download + sign the device binary
#   ./demo-scripts/agentdesktop-enrol-mac.sh hosts     print the /etc/hosts lines
#   ./demo-scripts/agentdesktop-enrol-mac.sh preview   enrol, then diff without writing
#   ./demo-scripts/agentdesktop-enrol-mac.sh up        enrol and stay running
#   ./demo-scripts/agentdesktop-enrol-mac.sh check     credential + a call through the gateway
#   ./demo-scripts/agentdesktop-enrol-mac.sh settings  what got written into Claude Code
#   ./demo-scripts/agentdesktop-enrol-mac.sh state     which demo owns Claude right now
#   ./demo-scripts/agentdesktop-enrol-mac.sh down      unenrol and put Claude back
#
# Sharing a laptop with the other gateway demo. Claude Code has one place for a
# base URL and one for a credential helper, and both demos use them: the
# task-routing lab's agw-toggle.sh, and this one. They cannot both be on. `up`
# refuses to start while agw-toggle is on, and `down` restores the settings
# that were in place before this lab touched anything.
#
# By default this writes to Claude Code's real settings file, which affects
# every Claude Code session on this machine. Set AD_SAFE=1 to send the managed
# file to /tmp instead, which is the right choice if you are presenting from
# Claude Code on the same laptop.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.agentdesktop-env" ] || { echo "run ./demo-scripts/agentdesktop.sh first"; exit 1; }
. "$SCRIPT_DIR/.agentdesktop-env"

# Use whatever is on PATH, else a copy this script downloaded, else explain how
# to get one. AD_BIN overrides all of it.
AD_VERSION="${AD_VERSION:-v0.1.1}"
BIN_DIR="$SCRIPT_DIR/.agentdesktop-bin"
AD_BIN="${AD_BIN:-}"
if [ -z "$AD_BIN" ]; then
  if command -v agentdesktop >/dev/null 2>&1; then AD_BIN="$(command -v agentdesktop)"
  else AD_BIN="$BIN_DIR/agentdesktop"; fi
fi
CFG="$SCRIPT_DIR/yaml-agentdesktop/daemon.yaml"
CA=/tmp/agentdesktop-device-ca.pem
CTRL_HOST=agentdesktop.agentdesktop.svc.cluster.local
KC_HOST=keycloak.keycloak.svc.cluster.local
SOCK="$HOME/.local/state/agentdesktop/agentdesktop.sock"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
BASELINE="$CLAUDE_SETTINGS.pre-agentdesktop"
# agw-toggle.sh keeps its own untouched original here. When it exists it is the
# real default for this machine, whatever the live file happens to say now.
AGW_BASELINE="$CLAUDE_SETTINGS.pre-agw"
STATE_DIR="$HOME/.local/state/agentdesktop"

need_hosts() { ! grep -q "$CTRL_HOST" /etc/hosts || ! grep -q "$KC_HOST" /etc/hosts; }

claude_base() {
  python3 -c "import json,os,sys; p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}; print(d.get('env',{}).get('ANTHROPIC_BASE_URL',''))" "$CLAUDE_SETTINGS" 2>/dev/null
}

other_demo_on() {
  b="$(claude_base)"
  [ -n "$b" ] || return 1
  case "$b" in *"$AD_GATEWAY"*) return 1 ;; *) return 0 ;; esac
}

guard_other_demo() {
  other_demo_on || return 0
  cat <<EOF

Claude Code is pointed at the other demo's gateway:

  $(claude_base)

Both demos write the same two keys, so they cannot be on together. Turn that
one off first, then come back:

  ~/Downloads/agw-toggle.sh off

EOF
  exit 1
}

snapshot_baseline() {
  [ -f "$BASELINE" ] && return 0
  if [ -f "$AGW_BASELINE" ]; then cp "$AGW_BASELINE" "$BASELINE"
  elif [ -f "$CLAUDE_SETTINGS" ]; then cp "$CLAUDE_SETTINGS" "$BASELINE"
  else echo '{}' > "$BASELINE"; fi
  echo "-> baseline saved: $BASELINE"
}

have_bin() { [ -x "$AD_BIN" ]; }
need_bin() {
  have_bin || { echo "No agentdesktop binary found."; echo "Run: $0 binary"; exit 1; }
}

case "${1:-up}" in

binary)
  # The release assets are not signed, so macOS kills the binary on launch
  # until it carries an ad-hoc signature.
  OS=darwin; [ "$(uname -s)" = "Linux" ] && OS=linux
  ARCH=arm64; [ "$(uname -m)" = "x86_64" ] && ARCH=amd64
  ASSET="agentdesktop-${OS}-${ARCH}"
  mkdir -p "$BIN_DIR"; cd "$BIN_DIR"
  echo "→ downloading $ASSET ($AD_VERSION)"
  if command -v gh >/dev/null 2>&1; then
    gh release download "$AD_VERSION" --repo agentdesktop-dev/agentdesktop \
      --pattern "${ASSET}*" --dir . --clobber
  else
    base="https://github.com/agentdesktop-dev/agentdesktop/releases/download/$AD_VERSION"
    curl -fsSL -o "$ASSET" "$base/$ASSET"
    curl -fsSL -o "$ASSET.sha256" "$base/$ASSET.sha256"
  fi
  shasum -a 256 -c "$ASSET.sha256"
  mv -f "$ASSET" agentdesktop && chmod +x agentdesktop
  [ "$OS" = darwin ] && codesign --force --sign - agentdesktop
  echo "→ $BIN_DIR/agentdesktop"
  ./agentdesktop --help >/dev/null && echo "✔ runs"
  ;;

hosts)
  cat <<EOF
Add these two lines to /etc/hosts, then re-run. The controller certificate is
issued for its cluster DNS name and the OIDC issuer uses the same form of
name, so the laptop has to resolve both the way the cluster does.

  sudo tee -a /etc/hosts <<'HOSTS'
$AD_CONTROLLER_IP $CTRL_HOST
$AD_KEYCLOAK_IP $KC_HOST
HOSTS
EOF
  ;;

preview)
  need_hosts && { "$0" hosts; exit 1; }
  need_bin; guard_other_demo; snapshot_baseline
  [ -f "$CA" ] || { echo "no device CA at $CA. Re-run agentdesktop.sh"; exit 1; }
  echo "→ enrols to collect the policy, then prints the diff and writes nothing"
  if [ "${AD_SAFE:-0}" = "1" ]; then
    "$AD_BIN" daemon --user --config "$CFG" --claude-code-settings /tmp/agentdesktop-claude-settings.json --dry-run
  else
    "$AD_BIN" daemon --user --config "$CFG" --dry-run
  fi
  ;;

up)
  need_hosts && { "$0" hosts; exit 1; }
  need_bin; guard_other_demo; snapshot_baseline
  echo "→ starting the daemon. A browser opens: sign in as tom / password."
  [ "${AD_SAFE:-0}" = "1" ] && echo "  (AD_SAFE=1: managed Claude Code settings go to /tmp)"
  # macOS /bin/bash 3.2 + set -u treats an empty array expansion as unbound.
  if [ "${AD_SAFE:-0}" = "1" ]; then
    exec "$AD_BIN" daemon --user --config "$CFG" --claude-code-settings /tmp/agentdesktop-claude-settings.json
  else
    exec "$AD_BIN" daemon --user --config "$CFG"
  fi
  ;;

status)
  "$AD_BIN" status
  curl -sS --unix-socket "$SOCK" http://localhost/v1/enrollment 2>/dev/null; echo
  "$AD_BIN" discover
  ;;

check)
  TOK="$("$AD_BIN" credential --client-id claude-code)"
  echo "→ credential claims"
  echo "$TOK" | cut -d. -f2 | tr '_-' '/+' | base64 -D 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k:d.get(k) for k in ("iss","aud","email","client_id")}|{"lifetime":d["exp"]-d["iat"]}, indent=1))'
  echo "→ through the gateway"
  curl -sS -m 60 "http://$AD_GATEWAY/v1/messages" \
    -H "Authorization: Bearer $TOK" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"claude-haiku-4-5","max_tokens":40,"messages":[{"role":"user","content":"Reply with exactly: enrolled and routed"}]}'
  echo
  ;;

settings)
  F="$HOME/.claude/settings.json"
  [ "${AD_SAFE:-0}" = "1" ] && F=/tmp/agentdesktop-claude-settings.json
  echo "→ $F"
  python3 -c "
import json,sys
d=json.load(open('$F'))
keep={k:d[k] for k in ('apiKeyHelper','companyAnnouncements','env','sandbox') if k in d}
print(json.dumps(keep, indent=2))"
  ;;

state)
  b="$(claude_base)"
  echo
  printf '  %-22s %s\n' "Claude base URL" "${b:-(none, default)}"
  if [ -z "$b" ]; then                      echo "  owner                  nobody: Claude is on its default settings"
  elif other_demo_on; then                  echo "  owner                  the task-routing demo (agw-toggle.sh)"
  else                                      echo "  owner                  this lab (demo-9 agentdesktop)"; fi
  [ -f "$BASELINE" ]     && printf '  %-22s %s\n' "this lab's baseline" "$BASELINE"
  [ -f "$AGW_BASELINE" ] && printf '  %-22s %s\n' "machine default"     "$AGW_BASELINE"
  if [ -S "$SOCK" ]; then
    printf '  %-22s %s\n' "agentdesktop daemon" "running"
    printf '  %-22s %s\n' "enrolment" "$(curl -sS --unix-socket "$SOCK" http://localhost/v1/enrollment 2>/dev/null)"
  else
    printf '  %-22s %s\n' "agentdesktop daemon" "not running"
  fi
  echo
  ;;

down)
  # Order matters. Putting Claude Code back is the part that must not be
  # skipped, so it happens before anything that touches the network. Every
  # remote step afterwards is best effort and cannot abort the script.
  pkill -f "agentdesktop daemon" 2>/dev/null && echo "-> daemon stopped" || echo "-> daemon was not running"
  sleep 1

  if [ -f "$BASELINE" ]; then
    [ -f "$CLAUDE_SETTINGS" ] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$BASELINE" "$CLAUDE_SETTINGS"
    echo "-> Claude Code restored from $BASELINE"
  elif [ -f "$AGW_BASELINE" ]; then
    cp "$AGW_BASELINE" "$CLAUDE_SETTINGS"
    echo "-> Claude Code restored from the machine default $AGW_BASELINE"
  else
    echo "-> no baseline recorded; leaving Claude Code alone"
  fi
  rm -f /tmp/agentdesktop-claude-settings.json

  if [ -d "$STATE_DIR" ]; then
    rm -rf "${STATE_DIR:?}"/* 2>/dev/null || true
    echo "-> local device identity cleared"
  fi
  rm -f "$HOME/Library/LaunchAgents/dev.agentdesktop.daemon.user.plist" 2>/dev/null || true

  # Best effort from here: a ghost row in the console is cosmetic, and an
  # unreachable cluster must not stop a laptop being put back.
  set +e
  if command -v kubectl >/dev/null 2>&1; then
    PF_PORT=18099; PF=""
    if ! curl -sS -m 2 "http://127.0.0.1:$PF_PORT/api/v1/overview" >/dev/null 2>&1; then
      kubectl -n agentdesktop port-forward deploy/agentdesktop $PF_PORT:8080 >/tmp/ad-down-pf.log 2>&1 &
      PF=$!; sleep 4
    fi
    IDS="$(curl -sS -m 5 "http://127.0.0.1:$PF_PORT/api/v1/devices" 2>/dev/null | python3 -c "
import json,socket,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
ds=d if isinstance(d,list) else d.get('devices',d)
hn=socket.gethostname().split('.')[0]
for x in ds:
    if str(x.get('hostname','')).split('.')[0]==hn: print(x['id'])
" 2>/dev/null)"
    for id in $IDS; do
      curl -sS -m 5 -o /dev/null -X DELETE "http://127.0.0.1:$PF_PORT/api/v1/devices/$id" \
        && echo "-> device $id removed from the controller"
    done
    [ -n "$PF" ] && kill "$PF" 2>/dev/null
    [ -z "$IDS" ] && echo "-> no device for this hostname in the controller (nothing to remove)"
  fi
  set -e

  echo
  echo "Restart Claude Code and Claude Desktop to pick it up."
  echo "The other demo is free now:  ~/Downloads/agw-toggle.sh on"
  ;;

*) echo "usage: $0 {binary|hosts|preview|up|status|check|settings|state|down}"; exit 1 ;;
esac
