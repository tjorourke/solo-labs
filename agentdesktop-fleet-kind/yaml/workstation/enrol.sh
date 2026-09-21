#!/usr/bin/env bash
# enrol.sh — bring one simulated workstation up and enrol it with the controller.
#
# A real laptop enrols through a browser: the daemon opens the identity
# provider, the engineer signs in, and the loopback redirect hands the code
# back. A container has no browser, so this drives the same authorization code
# flow with curl against Keycloak's login form. The daemon, the CSR, the device
# certificate and the enrolment records are all the real thing; only the
# button-clicking is scripted.
set -Eeuo pipefail

: "${AD_CONTROLLER_IP:?}" "${AD_KEYCLOAK_IP:?}" "${AD_USER:?}" "${AD_PASSWORD:?}"
CONTROLLER_HOST=agentdesktop.agentdesktop.svc.cluster.local
KEYCLOAK_HOST=keycloak.keycloak.svc.cluster.local
JAR=/tmp/kc-cookies.txt
# --user manages this user's own tool settings. System mode manages the machine's, and
# it is the only mode that can reach Claude Desktop: Desktop reads its policy from the
# system-managed location, and --user refuses programs.claudeDesktop for the whole
# revision, which leaves every other program on the device unmanaged too. Set
# AD_SYSTEM=1 when the fleet policy carries Claude Desktop.
if [ "${AD_SYSTEM:-0}" = "1" ]; then
  MODE=""
  MODE_LABEL=system
  SOCK=/run/agentdesktop/agentdesktop.sock
  STATE=/var/lib/agentdesktop
else
  MODE="--user"
  MODE_LABEL=user
  SOCK="$HOME/.local/state/agentdesktop/agentdesktop.sock"
  STATE="$HOME/.local/state/agentdesktop"
fi

# Resolve the two cluster names the same way the laptop does with /etc/hosts.
grep -q "$CONTROLLER_HOST" /etc/hosts || echo "$AD_CONTROLLER_IP $CONTROLLER_HOST" >> /etc/hosts
grep -q "$KEYCLOAK_HOST"   /etc/hosts || echo "$AD_KEYCLOAK_IP $KEYCLOAK_HOST"   >> /etc/hosts

# Give this workstation something to find. Discovery is the real code path: it
# looks for a `claude` executable on PATH, reads ~/.claude.json for MCP servers
# and walks ~/.claude/skills for SKILL.md front matter. The tools here are
# stand-ins, but nothing about the discovery is faked, and each machine gets a
# different set so the fleet inventory shows what shadow AI actually looks like.
seed_tools() {
  printf '#!/bin/sh\necho "claude 2.0.31"\n' > /usr/local/bin/claude
  chmod +x /usr/local/bin/claude
  mkdir -p "$HOME/.claude/skills"
  # Keep the default out of a ${VAR:-...} expansion: a brace in the default
  # closes the expansion early and appends the remainder as literal text.
  if [ -z "${AD_MCP_JSON:-}" ]; then AD_MCP_JSON='{"mcpServers":{}}'; fi
  printf '%s' "$AD_MCP_JSON" > "$HOME/.claude.json"
  for s in ${AD_SKILLS:-}; do
    mkdir -p "$HOME/.claude/skills/$s"
    printf -- '---\nname: %s\ndescription: %s helper used by this team\n---\n' "$s" "$s" \
      > "$HOME/.claude/skills/$s/SKILL.md"
  done
}
seed_tools

mkdir -p "$HOME/.config/agentdesktop" "$STATE" "$(dirname "$SOCK")"
cat > "$HOME/.config/agentdesktop/config.yaml" <<EOF
controller:
  address: https://$CONTROLLER_HOST
  caCertificatePath: /etc/agentdesktop/device-ca.pem
  heartbeatInterval: 30s
EOF

echo "→ [$(hostname)] starting daemon in $MODE_LABEL mode"
# shellcheck disable=SC2086
agentdesktop daemon $MODE --config "$HOME/.config/agentdesktop/config.yaml" \
  --state-dir "$STATE" --socket "$SOCK" \
  > /tmp/daemon.log 2>&1 &
DAEMON_PID=$!

sock() { curl -sS --unix-socket "$SOCK" "http://localhost$1"; }

# The daemon publishes the authorization URL as soon as it needs a sign-in.
AUTH_URL=""
for _ in $(seq 1 60); do
  if [ -S "$SOCK" ]; then
    AUTH_URL="$(sock /v1/enrollment 2>/dev/null | jq -r '.authorizationUrl // empty')"
    [ -n "$AUTH_URL" ] && break
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || { echo "daemon exited early:"; cat /tmp/daemon.log; exit 1; }
  sleep 1
done
[ -n "$AUTH_URL" ] || { echo "no authorization URL from the daemon:"; cat /tmp/daemon.log; exit 1; }
echo "→ [$(hostname)] signing in as $AD_USER"

# Keycloak renders a login form whose action carries the session state. Post
# the credentials to it and follow the redirect back to the daemon's loopback
# listener, which is what a browser would do.
rm -f "$JAR"
LOGIN_PAGE="$(curl -sS -c "$JAR" -L "$AUTH_URL")"
ACTION="$(printf '%s' "$LOGIN_PAGE" \
  | grep -oE '<form[^>]+id="kc-form-login"[^>]*>' \
  | grep -oE 'action="[^"]+"' | head -1 | sed 's/^action="//; s/"$//' \
  | sed 's/&amp;/\&/g')"
[ -n "$ACTION" ] || { echo "could not find the Keycloak login form"; exit 1; }

curl -sS -b "$JAR" -c "$JAR" -o /dev/null \
  --data-urlencode "username=$AD_USER" \
  --data-urlencode "password=$AD_PASSWORD" \
  --data-urlencode "credentialId=" \
  -L "$ACTION"

# Enrolment completes asynchronously once the callback lands.
for _ in $(seq 1 60); do
  STATUS="$(sock /v1/enrollment 2>/dev/null | jq -r '.status // empty')"
  [ "$STATUS" = "enrolled" ] && { echo "→ [$(hostname)] enrolled"; break; }
  sleep 1
done
[ "${STATUS:-}" = "enrolled" ] || { echo "enrolment did not complete (status=${STATUS:-none}):"; cat /tmp/daemon.log; exit 1; }

# Stay up so the device keeps heartbeating and shows as connected.
wait "$DAEMON_PID"
