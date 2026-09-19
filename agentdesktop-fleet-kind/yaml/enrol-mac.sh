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

SAFE_ARGS=()
if [ "${AD_SAFE:-0}" = "1" ]; then
  SAFE_ARGS=(--claude-code-settings /tmp/agentdesktop-claude-settings.json)
fi

need_hosts() { ! grep -q "$CTRL_HOST" /etc/hosts || ! grep -q "$KC_HOST" /etc/hosts; }

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
  need_bin
  [ -f "$CA" ] || { echo "no device CA at $CA. Re-run agentdesktop.sh"; exit 1; }
  echo "→ enrols to collect the policy, then prints the diff and writes nothing"
  "$AD_BIN" daemon --user --config "$CFG" "${SAFE_ARGS[@]}" --dry-run
  ;;

up)
  need_hosts && { "$0" hosts; exit 1; }
  need_bin
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

*) echo "usage: $0 {binary|hosts|preview|up|status|check|settings}"; exit 1 ;;
esac
