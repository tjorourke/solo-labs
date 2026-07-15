#!/usr/bin/env bash
# refresh-tokens.sh — re-mint the two agent identity tokens from Keycloak and
# update the Secrets the RemoteMCPServers inject. Run this if the tokens have
# expired (the realm sets a 12h lifespan). Restarts the agent pods so kagent
# re-reads the Secrets.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

for pair in "agent-diagnoser:agent-token-reader" "agent-remediator:agent-token-operator"; do
  user="${pair%%:*}"; secret="${pair##*:}"
  tok="$(mint_keycloak_token "$user")"
  [[ -n "$tok" ]] || die "could not mint token for $user"
  kc -n kagent create secret generic "$secret" \
    --from-literal=authorization="Bearer ${tok}" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "refreshed $secret ($user)"
done
kc -n kagent rollout restart deploy -l kagent.dev/agent=dba-diagnoser  >/dev/null 2>&1 || true
kc -n kagent rollout restart deploy -l kagent.dev/agent=sre-remediator >/dev/null 2>&1 || true
ok "agent pods restarted to pick up the new tokens"
