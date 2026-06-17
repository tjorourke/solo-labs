#!/usr/bin/env bash
# 03-apps.sh — ensure the version-stamped echo app is deployed in both app
# clusters. Identical to part 1, idempotent, so it reuses the apps if they are
# already there.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

deploy_echo() {
  local ctx="$1" version="$2"
  log "deploying echo (version=$version) to $ctx"
  sed "s/__CLUSTER_VERSION__/${version}/g" "$LAB_ROOT/yaml/app/echo.yaml" \
    | kctx "$ctx" apply -f - >/dev/null
  wait_deploy "$ctx" echo echo 180s
  ok "echo (version=$version) Available on $ctx"
}

step "Ensuring versioned echo apps"
deploy_echo "$APP_LATEST_CTX" latest
deploy_echo "$APP_V2_CTX"     v2

step "App clusters reachable at (node IP : NodePort $APP_NODEPORT)"
echo "  app-latest:  $(kind_node_ip "$APP_LATEST_CLUSTER"):${APP_NODEPORT}" >&2
echo "  app-v2:      $(kind_node_ip "$APP_V2_CLUSTER"):${APP_NODEPORT}" >&2
echo "  Next:        ./scripts/04-routing.sh" >&2
