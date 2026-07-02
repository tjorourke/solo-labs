#!/usr/bin/env bash
# Deploy the echo backend, the Gateway and the HTTPRoute.
source "$(dirname "$0")/lib.sh"
step "Deploying echo app + Gateway + HTTPRoute"
k apply -f "${ROOT}/yaml/01-echo.yaml"
k apply -f "${ROOT}/yaml/02-gateway.yaml"
k -n demo rollout status deploy/echo --timeout=120s
k -n kgateway-system rollout status deploy/http --timeout=180s || true
