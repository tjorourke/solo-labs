#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
kind delete cluster --name "$CLUSTER" || true
[ -d "${ROOT}/.openmeter/quickstart" ] && ( cd "${ROOT}/.openmeter/quickstart" && docker compose down -v ) || true
