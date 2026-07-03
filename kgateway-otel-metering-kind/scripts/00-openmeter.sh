#!/usr/bin/env bash
# Bring up self-hosted OpenMeter OSS (docker compose quickstart). Vendor-neutral, no account.
source "$(dirname "$0")/lib.sh"
step "Starting self-hosted OpenMeter (docker compose quickstart)"
WORK="${ROOT}/.openmeter"
if [ ! -d "$WORK" ]; then
  git clone --depth 1 https://github.com/openmeterio/openmeter.git "$WORK"
fi
( cd "$WORK/quickstart" && docker compose up -d )
step "Waiting for OpenMeter API on ${OM_URL}"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${OM_URL}/api/v1/meters" || true)
  [ "$code" = "200" ] && { echo "OpenMeter ready"; exit 0; }
  sleep 2
done
echo "OpenMeter did not become ready" >&2; exit 1
