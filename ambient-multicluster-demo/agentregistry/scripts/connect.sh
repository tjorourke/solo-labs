#!/usr/bin/env bash
# connect.sh — SOURCE from the notebook's Connect cell:  source scripts/connect.sh
# Loads the mesh1 platform facts, puts arctl on PATH, and logs the CLI in to the
# in-cluster AgentRegistry as admin-user (Keycloak group admins -> registry
# superuser + kagent Admin). Sourced, so the exports persist into the kernel.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# a stale ARCTL_API_TOKEN in the shell wins over the `user login` token and makes
# every call 401 — clear it so plain arctl uses the fresh login token.
unset ARCTL_API_TOKEN

arctl_login && ok "arctl logged in to ${ARCTL_API_BASE_URL} as ${AS_USER}" \
            || warn "arctl login failed — check the platform is up (setup-mesh1.sh)"
