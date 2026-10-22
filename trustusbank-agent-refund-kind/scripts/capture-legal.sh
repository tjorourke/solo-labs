#!/usr/bin/env bash
set -Eeuo pipefail
# Retrieval status is separate from the wording supplied and verified 21 Oct 2026.
for url in 'https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32022R2554'; do
  printf 'Source: %s\n' "$url"
  curl -sSL --max-time 30 -o /dev/null -w 'HTTP %{http_code}\n' "$url" || true
done
printf 'DORA Article 9 wording verified 21 Oct 2026; see the mapping and source in the guide.\n'
