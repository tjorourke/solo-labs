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
# System mode. Agentdesktop can only manage Claude Desktop from here: Desktop reads its
# policy through CFPreferencesCopyAppValue against /Library/Managed Preferences, and a
# daemon running as the logged-in user cannot write that. `--user` refuses
# programs.claudeDesktop outright, and it refuses the whole revision, so a fleet policy
# with Claude Desktop in it leaves Claude Code unmanaged as well.
SYS_STATE_DIR=/var/lib/agentdesktop
SYS_SOCK=/var/run/agentdesktop/agentdesktop.sock
SYS_CODE_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.d/50-agentdesktop.json"
SYS_DESKTOP_PLIST="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
SYS_DESKTOP_HELPER=/etc/claude-desktop/agentdesktop-credential-helper
# The path the product itself looks for. Agentdesktop's own desktop app defers to a
# system LaunchDaemon here and removes its per-user fallback when it finds one, so
# installing at this path is the supported shape rather than a demo invention.
SYS_LABEL=dev.agentdesktop.daemon
SYS_PLIST="/Library/LaunchDaemons/$SYS_LABEL.plist"
SYS_BIN=/usr/local/bin/agentdesktop
SYS_ETC=/etc/agentdesktop
SYS_LOG=/var/log/agentdesktop-daemon.log

need_hosts() { ! grep -q "$CTRL_HOST" /etc/hosts || ! grep -q "$KC_HOST" /etc/hosts; }

# Each enrol mints a new device id. Logout only clears the local identity, so
# failed or repeated enrols leave Mac rows in the fleet console. The mesh1
# fleet is Linux; any macos/darwin record, or this hostname, is this laptop.
remove_controller_device() {
  local PF_PORT=18099 PF="" IDS
  if ! curl -sS -m 2 "http://127.0.0.1:$PF_PORT/api/v1/overview" >/dev/null 2>&1; then
    kubectl --context "${CTX:-kind-mesh1}" -n agentdesktop port-forward deploy/agentdesktop $PF_PORT:8080 >/tmp/ad-down-pf.log 2>&1 &
    PF=$!; sleep 4
  fi
  IDS="$(curl -sS -m 5 "http://127.0.0.1:$PF_PORT/api/v1/devices" 2>/dev/null | python3 -c "
import json,socket,subprocess,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
ds=d if isinstance(d,list) else d.get('devices') or []
names={socket.gethostname().split('.')[0].lower()}
for key in ('ComputerName','LocalHostName','HostName'):
    p=subprocess.run(['scutil','--get',key], capture_output=True, text=True)
    if p.returncode==0 and p.stdout.strip():
        names.add(p.stdout.strip().split('.')[0].lower())
for x in ds:
    osn=str(x.get('os') or '').lower()
    hn=str(x.get('hostname') or '').split('.')[0].lower()
    if osn in ('macos','darwin') or hn in names:
        print(x['id'])
" 2>/dev/null)"
  for id in $IDS; do
    curl -sS -m 5 -o /dev/null -X DELETE "http://127.0.0.1:$PF_PORT/api/v1/devices/$id" \
      && echo "-> device $id removed from the controller"
  done
  [ -n "$PF" ] && kill "$PF" 2>/dev/null
  [ -z "$IDS" ] && echo "-> no leftover device for this Mac in the controller"
}

claude_base() {
  python3 -c "import json,os,sys; p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}; print(d.get('env',{}).get('ANTHROPIC_BASE_URL',''))" "$CLAUDE_SETTINGS" 2>/dev/null
}

other_demo_on() {
  b="$(claude_base)"
  [ -n "$b" ] || return 1
  case "$b" in *"$AD_GATEWAY"*) return 1 ;; *) return 0 ;; esac
}

# agw-toggle.sh writes the same managed plist by hand, so system mode and that demo
# cannot both own Claude Desktop.
guard_other_demo_desktop() {
  [ -f "$SYS_DESKTOP_PLIST" ] || return 0
  [ -f "$SYS_DESKTOP_PLIST.owner" ] && return 0
  cat <<EOF

Claude Desktop already has a managed inference profile that Agentdesktop did not write:

  $SYS_DESKTOP_PLIST

That is the task-routing demo's toggle. Turn it off first, then come back:

  ~/Downloads/agw-toggle.sh off

EOF
  exit 1
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

install-daemon)
  # One authorisation, then the daemon is the machine's and everything else is policy.
  # macOS asks for it in its own dialog, so this works from the demo console as well as
  # from a terminal.
  need_hosts && { "$0" hosts; exit 1; }
  need_bin; guard_other_demo_desktop
  [ -f "$CA" ] || { echo "no device CA at $CA. Re-run agentdesktop.sh"; exit 1; }
  PRIV="$(mktemp -t ad-install)"
  trap 'rm -f "$PRIV"' EXIT
  cat > "$PRIV" <<SH
set -e
/usr/bin/install -d -m 755 -o root -g wheel "$SYS_ETC" /var/lib/agentdesktop
/usr/bin/install -m 755 -o root -g wheel "$AD_BIN" "$SYS_BIN"
/usr/bin/install -m 644 -o root -g wheel "$CA" "$SYS_ETC/device-ca.pem"
cat > "$SYS_ETC/config.yaml" <<'CFG'
controller:
  address: https://$CTRL_HOST
  caCertificatePath: $SYS_ETC/device-ca.pem
  heartbeatInterval: 30s
CFG
chmod 644 "$SYS_ETC/config.yaml"
# A root daemon serves its socket to one group rather than to everyone, and refuses to
# start if that group is missing.
/usr/sbin/dseditgroup -o read agentdesktop >/dev/null 2>&1 || /usr/sbin/dseditgroup -o create agentdesktop
/usr/sbin/dseditgroup -o edit -a "$(id -un)" -t user agentdesktop >/dev/null 2>&1 || true
# World readable: the console reads the sign-in URL out of here rather than needing the
# socket, so it does not have to be restarted to pick up the new group membership.
[ -f "$SYS_LOG" ] || /usr/bin/install -m 644 -o root -g wheel /dev/null "$SYS_LOG"
cat > "$SYS_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SYS_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SYS_BIN</string>
    <string>--socket</string><string>$SYS_SOCK</string>
    <string>daemon</string>
    <string>--config</string><string>$SYS_ETC/config.yaml</string>
    <string>--state-dir</string><string>/var/lib/agentdesktop</string>
    <string>--oidc-callback-listen</string><string>127.0.0.1:51327</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$SYS_LOG</string>
  <key>StandardErrorPath</key><string>$SYS_LOG</string>
</dict>
</plist>
PLIST
chown root:wheel "$SYS_PLIST"
chmod 644 "$SYS_PLIST"
/bin/launchctl bootout system/$SYS_LABEL >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$SYS_PLIST"
/bin/launchctl enable system/$SYS_LABEL
/bin/launchctl kickstart -k system/$SYS_LABEL
SH
  echo "→ macOS will ask for your password once, to install the daemon."
  osascript -e 'on run argv' \
    -e 'do shell script "/bin/sh " & quoted form of (item 1 of argv) & " 2>&1" with administrator privileges' \
    -e 'end run' "$PRIV"
  echo "-> daemon installed and running as the machine"
  # System mode leaves ~/.claude/settings.json alone, which is wrong on a laptop
  # configured for Vertex: CLAUDE_CODE_USE_VERTEX survives in the user file and
  # sends the Agentdesktop token to the Vertex front door, which 401s with
  # 'token uses the unknown key "agentdesktop"'. This watcher parks the Vertex
  # keys while the managed file exists and puts them back when it goes.
  # Idempotent, and a no-op on a machine that never had Vertex configured.
  "$(dirname "$0")/claude-vertex-reconcile.sh" install || \
    echo "   (vertex watcher failed to install; run claude-vertex-reconcile.sh status)"
  echo "   Sign in with:  $0 signin-url"
  ;;

remove-daemon)
  # Claude Desktop caches its managed preferences, so it goes before the file does.
  osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
  PRIV="$(mktemp -t ad-remove)"
  trap 'rm -f "$PRIV"' EXIT
  cat > "$PRIV" <<SH
/bin/launchctl bootout system/$SYS_LABEL >/dev/null 2>&1 || true
rm -f "$SYS_PLIST"
rm -rf "$(dirname "$SYS_SOCK")"
rm -f "$SYS_CODE_SETTINGS" "$(dirname "$SYS_CODE_SETTINGS")/.$(basename "$SYS_CODE_SETTINGS").owner"
# Only if Agentdesktop wrote it. Without the marker the managed profile belongs to
# agw-toggle.sh, and removing this daemon must not take the other demo down with it.
if [ -f "$(dirname "$SYS_DESKTOP_PLIST")/.$(basename "$SYS_DESKTOP_PLIST").owner" ]; then
  rm -f "$SYS_DESKTOP_PLIST" "$(dirname "$SYS_DESKTOP_PLIST")/.$(basename "$SYS_DESKTOP_PLIST").owner"
fi
rm -f "$SYS_DESKTOP_HELPER" "$(dirname "$SYS_DESKTOP_HELPER")/.$(basename "$SYS_DESKTOP_HELPER").owner"
rm -rf /var/lib/agentdesktop "$SYS_ETC" "$SYS_BIN" "$SYS_LOG"
SH
  osascript -e 'on run argv' \
    -e 'do shell script "/bin/sh " & quoted form of (item 1 of argv) & " 2>&1" with administrator privileges' \
    -e 'end run' "$PRIV"
  echo "-> daemon removed; both clients are back to native"
  echo "   Restart Claude Code, and reopen Claude Desktop."
  set +e
  command -v kubectl >/dev/null 2>&1 && remove_controller_device
  set -e
  ;;

signin-url)
  # The daemon's own prompt page, not the raw provider URL: it carries the state and
  # nonce the daemon is waiting on, and it is what the product's desktop app opens.
  #
  # Read it out of the tracing line rather than the plain one the daemon also prints.
  # Rust block-buffers stdout into a file, so that line can sit unflushed for a long
  # time, while tracing goes to stderr unbuffered. The tracing line is ANSI-coloured
  # even when it is not a terminal, and the escapes land *between* the field name and
  # the `=`, so the colour has to come off before anything can match.
  URL="$(python3 - "$SYS_LOG" <<'PYEOF' || true
import re, sys
try:
    raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except OSError:
    raise SystemExit
plain = re.sub(r"\x1b\[[0-9;]*m", "", raw)
found = re.findall(r"prompt_url=(http://127\.0\.0\.1:\d+/)", plain)
print(found[-1] if found else "", end="")
PYEOF
)"
  [ -n "$URL" ] || URL="$(curl -sS --unix-socket "$SYS_SOCK" http://localhost/v1/enrollment 2>/dev/null \
         | sed -n 's/.*"authorizationUrl":"\([^"]*\)".*/\1/p' || true)"
  [ -n "$URL" ] || { echo "no sign-in pending (already enrolled, or the daemon is not running)"; exit 1; }
  # A URL left behind by a finished enrolment points at a listener that has gone.
  case "$URL" in
    http://127.0.0.1:*)
      PORT="${URL#http://127.0.0.1:}"; PORT="${PORT%%/*}"
      nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "no sign-in pending (this device is already enrolled)"; exit 1; }
      ;;
  esac
  echo "$URL"
  ;;

daemon-state)
  printf '  %-22s %s\n' "launch daemon"  "$([ -f "$SYS_PLIST" ] && echo installed || echo "not installed")"
  printf '  %-22s %s\n' "running"        "$(pgrep -f "$SYS_BIN" >/dev/null && echo yes || echo no)"
  printf '  %-22s %s\n' "Claude Code"    "$([ -f "$SYS_CODE_SETTINGS" ] && echo managed || echo native)"
  printf '  %-22s %s\n' "Claude Desktop" "$([ -f "$SYS_DESKTOP_PLIST" ] && echo managed || echo native)"
  ;;

up-system)
  # Both clients. Runs as root so Claude Desktop's managed preferences can be written,
  # which is the only path that reaches Desktop at all.
  need_hosts && { "$0" hosts; exit 1; }
  need_bin; guard_other_demo; guard_other_demo_desktop
  [ -f "$CA" ] || { echo "no device CA at $CA. Re-run agentdesktop.sh"; exit 1; }
  echo "→ system mode: Claude Code and Claude Desktop"
  echo "  Claude Code   $SYS_CODE_SETTINGS"
  echo "  Claude Desktop $SYS_DESKTOP_PLIST"
  echo "  Your own ~/.claude/settings.json is not touched; the managed file wins over it."
  echo
  echo "→ sudo is needed for those two paths. A sign-in URL is printed: open it as bob / password."
  echo "  bob, not tom. The model gateway decides on the subject in the token, and its OPA"
  echo "  table knows bob, alice and dave. Any other subject gets 403 no suitable permitted"
  echo "  backend for this task on every request, from both clients."
  sudo mkdir -p "$SYS_STATE_DIR" "$(dirname "$SYS_SOCK")" \
                "$(dirname "$SYS_CODE_SETTINGS")" "$(dirname "$SYS_DESKTOP_HELPER")"
  # The browser opens in root's session or not at all, so bind the callback to a fixed
  # port and let the printed URL be the way in.
  exec sudo "$AD_BIN" daemon \
    --config "$CFG" \
    --state-dir "$SYS_STATE_DIR" \
    --socket "$SYS_SOCK" \
    --oidc-callback-listen 127.0.0.1:18456
  ;;

preview-system)
  need_hosts && { "$0" hosts; exit 1; }
  need_bin
  echo "→ enrols to collect the policy, prints the diff for both clients, writes nothing"
  sudo mkdir -p "$SYS_STATE_DIR" "$(dirname "$SYS_SOCK")"
  sudo "$AD_BIN" daemon --config "$CFG" --state-dir "$SYS_STATE_DIR" \
    --socket "$SYS_SOCK" --oidc-callback-listen 127.0.0.1:18456 --dry-run
  ;;

down-system)
  # Claude Desktop caches its managed preferences, so quit it before the file goes and
  # the next launch reads an absent profile rather than the one it started with.
  pkill -f "agentdesktop daemon" 2>/dev/null && echo "-> daemon stopped" || echo "-> daemon was not running"
  sudo pkill -f "agentdesktop daemon" 2>/dev/null || true
  sleep 1
  osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
  sudo rm -f "$SYS_CODE_SETTINGS" "$SYS_CODE_SETTINGS.owner" \
             "$SYS_DESKTOP_PLIST" "$SYS_DESKTOP_PLIST.owner" \
             "$SYS_DESKTOP_HELPER" "$SYS_DESKTOP_HELPER.owner"
  echo "-> managed files for both clients removed"
  sudo rm -rf "${SYS_STATE_DIR:?}" && echo "-> device identity cleared"
  sudo rm -rf "$(dirname "$SYS_SOCK")" 2>/dev/null || true
  set +e
  command -v kubectl >/dev/null 2>&1 && remove_controller_device
  set -e
  echo
  echo "Restart Claude Code, and reopen Claude Desktop."
  echo "The other demo is free now:  ~/Downloads/agw-toggle.sh on"
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
  if [ -f "$SYS_CODE_SETTINGS" ] || [ -f "$SYS_DESKTOP_PLIST" ]; then
    printf '  %-22s %s\n' "system mode" "on"
    [ -f "$SYS_CODE_SETTINGS" ] && printf '  %-22s %s\n' "  Claude Code" "managed"
    if [ -f "$SYS_DESKTOP_PLIST" ]; then
      if [ -f "$SYS_DESKTOP_PLIST.owner" ]; then
        printf '  %-22s %s\n' "  Claude Desktop" "managed by Agentdesktop"
      else
        printf '  %-22s %s\n' "  Claude Desktop" "managed by agw-toggle.sh"
      fi
    fi
  fi
  if [ -S "$SOCK" ] || [ -S "$SYS_SOCK" ]; then
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
  command -v kubectl >/dev/null 2>&1 && remove_controller_device
  set -e

  echo
  echo "Restart Claude Code and Claude Desktop to pick it up."
  echo "The other demo is free now:  ~/Downloads/agw-toggle.sh on"
  ;;

*) cat <<EOF
usage: $0 <action>

  Claude Code only, no sudo:
    binary hosts preview up status check settings state down

  Claude Code and Claude Desktop, one macOS authorisation:
    install-daemon signin-url daemon-state remove-daemon

  The same thing in the foreground, for watching it work:
    preview-system up-system down-system
EOF
   exit 1 ;;
esac
