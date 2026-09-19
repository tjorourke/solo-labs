#!/usr/bin/env bash
# agentdesktop-enrol-mac.sh — enrol this Mac with the controller and show the
# policy land in Claude Code's own settings file.
#
#   ./demo-scripts/agentdesktop-enrol-mac.sh hosts     print the /etc/hosts lines
#   ./demo-scripts/agentdesktop-enrol-mac.sh preview   enrol, then diff without writing
#   ./demo-scripts/agentdesktop-enrol-mac.sh up        enrol and stay running
#   ./demo-scripts/agentdesktop-enrol-mac.sh check     credential + a call through the gateway
#   ./demo-scripts/agentdesktop-enrol-mac.sh settings  what got written into Claude Code
#
# By default this writes to Claude Code's real settings file, which affects
# every Claude Code session on this machine. Set AD_SAFE=1 to send the managed
# file to /tmp instead, which is the right choice if you are presenting from
# Claude Code on the same laptop.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.agentdesktop-env" ] || { echo "run ./demo-scripts/agentdesktop.sh first"; exit 1; }
. "$SCRIPT_DIR/.agentdesktop-env"

AD_BIN="${AD_BIN:-$HOME/code/solo/agentdesktop/bin/agentdesktop}"
CFG="$SCRIPT_DIR/yaml-agentdesktop/daemon.yaml"
CA=/tmp/agentdesktop-device-ca.pem
CTRL_HOST=agentdesktop.agentdesktop.svc.cluster.local
KC_HOST=keycloak.keycloak.svc.cluster.local
SOCK="$HOME/.local/state/agentdesktop/agentdesktop.sock"

SAFE_ARGS=()
if [ "${AD_SAFE:-0}" = "1" ]; then
  SAFE_ARGS=(--claude-code-settings /tmp/agentdesktop-claude-settings.json)
fi

need_hosts() { ! grep -q "$CTRL_HOST" /etc/hosts || ! grep -q "$KC_HOST" /etc/hosts; }

case "${1:-up}" in

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
  [ -x "$AD_BIN" ] || { echo "no agentdesktop binary at $AD_BIN"; exit 1; }
  [ -f "$CA" ] || { echo "no device CA at $CA — re-run agentdesktop.sh"; exit 1; }
  echo "→ enrols to collect the policy, then prints the diff and writes nothing"
  "$AD_BIN" daemon --user --config "$CFG" "${SAFE_ARGS[@]}" --dry-run
  ;;

up)
  need_hosts && { "$0" hosts; exit 1; }
  [ -x "$AD_BIN" ] || { echo "no agentdesktop binary at $AD_BIN"; exit 1; }
  echo "→ starting the daemon. A browser opens: sign in as tom / password."
  [ "${AD_SAFE:-0}" = "1" ] && echo "  (AD_SAFE=1: managed Claude Code settings go to /tmp)"
  exec "$AD_BIN" daemon --user --config "$CFG" "${SAFE_ARGS[@]}"
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

*) echo "usage: $0 {hosts|preview|up|status|check|settings}"; exit 1 ;;
esac
