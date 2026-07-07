#!/usr/bin/env bash
# connect.sh — SOURCE from the notebook's first cell:  source scripts/connect.sh
# Loads .env.local, puts arctl on PATH, and logs the CLI in to the in-cluster
# AgentRegistry as admin-user (group admins -> registry superuser + kagent Admin).
# (Sourced, so exports persist into the notebook kernel. No set -e — a hiccup must
#  not kill the kernel.)
#
# Auth is the v2026.6.1 `arctl user login` password-credentials flow against the
# agentregistry realm (ar-cli-password). It reaches the issuer at
# http://keycloak.localtest.me, served by the agentgateway ingress (kind maps host
# :80 -> the gateway), so there's no port-forward to start first.
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
set -a
[ -f "$LAB_ROOT/.env.local" ] && . "$LAB_ROOT/.env.local"
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
set +a
export PATH="$HOME/.arctl/bin:$PATH"
export NO_COLOR=1 CLICOLOR=0             # clean arctl output (no color / terminal-probe escapes)
# The notebook Bash kernel inherits PROMPT_COMMAND from the launching terminal (e.g.
# cmux exports PROMPT_COMMAND=_cmux_prompt_command) but not the shell FUNCTION it names,
# so every cell ends with "bash: _cmux_prompt_command: command not found". A kernel needs
# no prompt hook, so drop it to keep the demo output clean.
unset PROMPT_COMMAND
# TERM: the notebook Bash kernel runs an interactive bash over a pty and INHERITS a real
# TERM (e.g. xterm-256color) from the launching terminal. arctl's colour library then emits
# terminal probes (OSC 11 background-colour `]11;?` + cursor-position `[6n`) that no terminal
# answers, so they leak into cell output and mangle table headers. Only TERM=dumb suppresses
# them (NO_COLOR does not). Force TERM=dumb when we're in the kernel (parent process is the
# Python kernel, or the pty has ECHO OFF as bash_kernel sets it); a real terminal that SOURCEs
# this keeps its TERM so readline/colours there are unaffected.
if ps -o comm= -p "$PPID" 2>/dev/null | grep -qi python \
   || stty -a 2>/dev/null | grep -Eq '(^|[[:space:]])-echo([[:space:],]|$)'; then
  export TERM=dumb
else
  : "${TERM:=dumb}"; export TERM
fi
export CLUSTER_NAME="${CLUSTER_NAME:-agentcore-demo}"
export AR_HOST="${AR_HOST:-agentregistry.localtest.me}"
export KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.localtest.me}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentregistry}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}}"
export ARCTL_API_BASE_URL="${ARCTL_API_BASE_URL:-http://${AR_HOST}}"
export AR_CLI_CLIENT="${AR_CLI_CLIENT:-ar-cli-password}"
export AS_USER="${AS_USER:-admin-user}"
export AS_PASSWORD="${AS_PASSWORD:-password}"

# --- mesh cert self-heal ----------------------------------------------------
# Heal an expired agentgateway XDS serving cert on a long-lived kind cluster before
# any registry call. Shared with reset.sh via scripts/heal-mesh.sh (see that file
# for the why). No-op on a healthy cluster; set SKIP_MESH_HEAL=1 to skip.
_SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$_SD/heal-mesh.sh" ] && . "$_SD/heal-mesh.sh"
[ -n "${SKIP_MESH_HEAL:-}" ] || _heal_mesh_certs

# Clear any ARCTL_API_TOKEN left in this shell by a setup step (agentcore.sh /
# 04d-connect-aws.sh export one, minted at that moment). arctl prefers that env var
# over the `user login` token, so a stale one makes every arctl call 401 even after
# a fresh login. Unset it so plain arctl commands use the login token below; the
# steps that need ARCTL_API_TOKEN re-mint it themselves.
unset ARCTL_API_TOKEN

OIDC_ISSUER="$KEYCLOAK_ISSUER" OIDC_CLIENT_ID="$AR_CLI_CLIENT" \
arctl user login \
  --oidc-flow password-credentials \
  --oidc-issuer-url "$KEYCLOAK_ISSUER" \
  --oidc-client-id "$AR_CLI_CLIENT" \
  --oidc-username "$AS_USER" --oidc-password "$AS_PASSWORD" >/dev/null 2>&1 \
  && _login=ok || _login="FAILED (is the gateway up so ${KEYCLOAK_ISSUER} resolves?)"
echo "arctl $(arctl version 2>/dev/null | awk '/arctl version/{print $3}') · login $_login · registry ${ARCTL_API_BASE_URL} · cluster kind-${CLUSTER_NAME}"
arctl get runtimes 2>/dev/null
