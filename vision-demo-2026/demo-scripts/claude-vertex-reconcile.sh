#!/usr/bin/env bash
# Keep ~/.claude/settings.json consistent with whoever owns Claude Code.
#
# Why this exists
# ---------------
# System-mode enrol (agentdesktop-enrol-mac.sh install-daemon) drops a managed
# file at
#
#   /Library/Application Support/ClaudeCode/managed-settings.d/50-agentdesktop.json
#
# carrying an apiKeyHelper that mints an Agentdesktop JWT, plus
# ANTHROPIC_BASE_URL pointing at the EKS model gateway. Managed settings beat
# user settings key by key, so the script assumes ~/.claude/settings.json can be
# left alone.
#
# That assumption breaks on a laptop configured for Vertex. CLAUDE_CODE_USE_VERTEX
# lives in the user file, managed never unsets it, and Claude Code picks the
# Vertex code path before it ever reads ANTHROPIC_BASE_URL. The result is the
# Agentdesktop token being posted to the Vertex front door, which answers:
#
#   API Error: 401 authentication failure: token uses the unknown key "agentdesktop"
#
# So: park the Vertex keys while Agentdesktop owns Claude Code, put them back
# when it lets go. Keyed on the managed file itself rather than on any button,
# so it is right no matter how you enrolled.
#
# Usage
#   claude-vertex-reconcile.sh reconcile    # apply the correct state (default)
#   claude-vertex-reconcile.sh status       # report, change nothing
#   claude-vertex-reconcile.sh install      # load the WatchPaths LaunchAgent
#   claude-vertex-reconcile.sh uninstall    # unload it, then reconcile once
#
# Pass --dry-run to reconcile to see the plan without writing.
set -euo pipefail

MANAGED="/Library/Application Support/ClaudeCode/managed-settings.d/50-agentdesktop.json"
SETTINGS="$HOME/.claude/settings.json"
SNAPSHOT="$HOME/.claude/settings.json.vertex-restore"
LOG="$HOME/.claude/vertex-reconcile.log"

LABEL=com.masterthemesh.claude-vertex-reconcile
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WATCH_DIR="/Library/Application Support/ClaudeCode/managed-settings.d"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Keys that select the Vertex code path or authenticate against the Vertex front
# door. ANTHROPIC_BASE_URL is deliberately absent: managed sets its own and wins,
# and the task-routing demo's agw-toggle.sh owns that key legitimately.
TOP_KEYS=(apiKeyHelper)
ENV_KEYS=(
  CLAUDE_CODE_USE_VERTEX
  CLAUDE_CODE_SKIP_VERTEX_AUTH
  ANTHROPIC_VERTEX_BASE_URL
  ANTHROPIC_VERTEX_PROJECT_ID
  CLOUD_ML_REGION
  ANTHROPIC_CUSTOM_HEADERS
  ANTHROPIC_AUTH_TOKEN
  CLAUDE_CODE_API_KEY_HELPER_TTL_MS
)

# Writes the record itself and echoes to stdout for interactive runs. The
# LaunchAgent sends stdout to /dev/null and only captures stderr, so an
# unexpected traceback still lands somewhere without every line appearing twice.
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# All JSON work happens in python3, which every macOS ships. Each call is
# independent so a failure can never leave a half-written settings file: writes
# go to a temp sibling and are renamed. Exit codes: 0 changed, 3 nothing to do,
# 1 refused (unreadable JSON) so a corrupt file is reported rather than rewritten.
NOOP=3
pyjson() {
  TOP_KEYS="${TOP_KEYS[*]}" ENV_KEYS="${ENV_KEYS[*]}" \
  SETTINGS="$SETTINGS" SNAPSHOT="$SNAPSHOT" NOOP="$NOOP" \
  python3 -c 'import os,sys; NOOP=int(os.environ["NOOP"]); exec(sys.stdin.read())'
}

has_vertex() {
  pyjson <<'EOF'
import json, os, sys, pathlib
p = pathlib.Path(os.environ["SETTINGS"])
if not p.exists():
    sys.exit(1)
try:
    s = json.loads(p.read_text() or "{}")
except json.JSONDecodeError:
    sys.exit(1)
env = s.get("env") or {}
top = os.environ["TOP_KEYS"].split()
ek = os.environ["ENV_KEYS"].split()
# apiKeyHelper alone is not proof of Vertex; the marker is the Vertex switch.
sys.exit(0 if "CLAUDE_CODE_USE_VERTEX" in env or any(k in env for k in ek if k.startswith("ANTHROPIC_VERTEX")) else 1)
EOF
}

strip_vertex() {
  local dry="$1"
  DRY="$dry" pyjson <<'EOF'
import json, os, pathlib, sys
settings = pathlib.Path(os.environ["SETTINGS"])
snap = pathlib.Path(os.environ["SNAPSHOT"])
dry = os.environ.get("DRY") == "1"
try:
    s = json.loads(settings.read_text() or "{}")
except (OSError, json.JSONDecodeError) as e:
    print(f"settings.json is unreadable ({e}); refusing to touch it")
    sys.exit(1)

top = os.environ["TOP_KEYS"].split()
ek = os.environ["ENV_KEYS"].split()
removed = [k for k in top if k in s] + [f"env.{k}" for k in ek if k in (s.get("env") or {})]
if not removed:
    print("nothing to strip")
    sys.exit(NOOP)
print("strip: " + ", ".join(removed))
if dry:
    sys.exit(0)

# Snapshot the file exactly as it stands, Vertex keys included. This is the only
# place the snapshot is written, and only ever from a Vertex-bearing file, so an
# already-stripped settings.json can never overwrite a good snapshot.
snap.write_text(json.dumps(s, indent=2) + "\n")

for k in top:
    s.pop(k, None)
env = s.get("env")
if isinstance(env, dict):
    for k in ek:
        env.pop(k, None)
    if not env:
        s.pop("env", None)

tmp = settings.with_suffix(settings.suffix + ".tmp")
tmp.write_text(json.dumps(s, indent=2) + "\n")
tmp.replace(settings)
EOF
}

restore_vertex() {
  local dry="$1"
  DRY="$dry" pyjson <<'EOF'
import json, os, pathlib, sys
settings = pathlib.Path(os.environ["SETTINGS"])
snap = pathlib.Path(os.environ["SNAPSHOT"])
dry = os.environ.get("DRY") == "1"
if not snap.exists():
    print("no snapshot to restore from")
    sys.exit(NOOP)

try:
    saved = json.loads(snap.read_text() or "{}")
    cur = json.loads(settings.read_text() or "{}") if settings.exists() else {}
except (OSError, json.JSONDecodeError) as e:
    print(f"settings.json or snapshot is unreadable ({e}); refusing to touch it")
    sys.exit(1)

top = os.environ["TOP_KEYS"].split()
ek = os.environ["ENV_KEYS"].split()

# Put back only the keys that were parked. Anything else edited while enrolled
# (model, plugins, permissions) stays as it is now, which a straight file copy
# would silently revert.
added = []
for k in top:
    if k in saved:
        cur[k] = saved[k]
        added.append(k)
senv = saved.get("env") or {}
if senv:
    env = cur.setdefault("env", {})
    for k in ek:
        if k in senv:
            env[k] = senv[k]
            added.append(f"env.{k}")
if not added:
    print("snapshot carries no vertex keys")
    sys.exit(NOOP)
print("restore: " + ", ".join(added))
if dry:
    sys.exit(0)

tmp = settings.with_suffix(settings.suffix + ".tmp")
tmp.write_text(json.dumps(cur, indent=2) + "\n")
tmp.replace(settings)
EOF
}

reconcile() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

  local out rc
  if [ -f "$MANAGED" ]; then
    if ! has_vertex; then
      log "agentdesktop owns Claude Code; vertex already parked (no change)"
      return 0
    fi
    log "agentdesktop owns Claude Code -> parking vertex config"
    out="$(strip_vertex "$dry")" && rc=0 || rc=$?
    log "  $out"
    [ "$rc" = 0 ] || return "$([ "$rc" = "$NOOP" ] && echo 0 || echo "$rc")"
    [ "$dry" = 1 ] && return 0
    log "  snapshot: $SNAPSHOT"
    log "  restart Claude Code to pick up the gateway"
  else
    if has_vertex; then
      log "agentdesktop not present; vertex already active (no change)"
      return 0
    fi
    log "agentdesktop gone -> restoring vertex config"
    out="$(restore_vertex "$dry")" && rc=0 || rc=$?
    log "  $out"
    [ "$rc" = 0 ] || return "$([ "$rc" = "$NOOP" ] && echo 0 || echo "$rc")"
    [ "$dry" = 1 ] && return 0
    log "  restart Claude Code to pick up vertex"
  fi
}

status() {
  echo "managed file : $([ -f "$MANAGED" ] && echo present || echo absent)   $MANAGED"
  echo "settings     : $SETTINGS"
  echo "vertex keys  : $(has_vertex && echo present || echo absent)"
  echo "snapshot     : $([ -f "$SNAPSHOT" ] && echo "present  $SNAPSHOT" || echo absent)"
  echo "launchagent  : $(launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo loaded || echo "not loaded")   $PLIST"
  echo
  echo "would do:"
  reconcile --dry-run
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF</string>
    <string>reconcile</string>
  </array>
  <key>WatchPaths</key>
  <array><string>$WATCH_DIR</string></array>
  <key>RunAtLoad</key><true/>
  <!-- launchd defaults to a 10s throttle, which held the job back long enough
       that an enrol looked like it had not fired at all. 2s is responsive and
       still coalesces the burst of writes the daemon makes when a policy lands. -->
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$LOG.launchd</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "-> loaded $LABEL"
  echo "   watching $WATCH_DIR"
  echo "   log      $LOG"
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "-> unloaded $LABEL"
  reconcile
}

case "${1:-reconcile}" in
  reconcile) reconcile "${2:-}" ;;
  status)    status ;;
  install)   install_agent; echo; reconcile ;;
  uninstall) uninstall_agent ;;
  *) echo "usage: $(basename "$0") {reconcile [--dry-run]|status|install|uninstall}" >&2; exit 2 ;;
esac
