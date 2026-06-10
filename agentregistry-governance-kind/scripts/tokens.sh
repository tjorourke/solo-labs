#!/usr/bin/env bash
# tokens.sh <alice|bob|carol> — mint that user's Keycloak token and print it.
#   TOKEN=$(./scripts/tokens.sh alice)
#   arctl get skills --registry-token "$TOKEN"
# Add -v to also pretty-print the claims on stderr.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

USER_NAME="${1:?usage: tokens.sh <alice|bob|carol> [-v]}"
TOK="$(mint_token "$USER_NAME")"
if [[ "${2:-}" == "-v" ]]; then
  echo "claims:" >&2
  decode_jwt "$TOK" | sed 's/^/  /' >&2
fi
printf '%s\n' "$TOK"
