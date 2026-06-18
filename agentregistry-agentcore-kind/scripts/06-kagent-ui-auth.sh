#!/usr/bin/env bash
# 06-kagent-ui-auth.sh — front the kagent Enterprise UI with an OIDC login so it
# works on local kind. The controller is already wired to Keycloak (03-kagent);
# this adds the browser-facing SSO front door:
#
#   1. patch the kagent-ui pod's nginx upstream to the real controller Service
#      (the chart hard-codes 127.0.0.1:8083, which 502s).
#   2. oauth2-proxy in front of kagent-ui — it runs the OIDC login against
#      Keycloak (confidential `oauth2-proxy` realm client), then injects the
#      bearer the controller needs. The UI's "Sign in with SSO" hits /oauth2/start.
#   3. a hostAlias so oauth2-proxy can resolve the issuer (keycloak.localtest.me)
#      to Keycloak's ClusterIP in-cluster.
#
# Browse at http://localhost:18007 after ./scripts/open-consoles.sh and log in as
# a real Keycloak user (alice / alice). No /etc/hosts, no sudo: keycloak.localtest.me
# resolves to 127.0.0.1 via public DNS for the browser.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require helm

NS=kagent
kc -n "$KEYCLOAK_NS" get svc keycloak >/dev/null 2>&1 || die "Keycloak not found — run ./scripts/02-keycloak.sh first"
kc -n "$NS" get deploy kagent-ui >/dev/null 2>&1 || die "kagent-ui not found — run ./scripts/03-kagent.sh (ui.enabled) first"

step "Patching kagent-ui nginx upstream -> controller Service"
# Done with kubectl apply AFTER the kagent helm release exists (03-kagent), so
# there is no server-side-apply conflict in a clean run.
kc -n "$NS" get cm kagent-ui-config -o yaml 2>/dev/null | \
  sed "s|server 127\.0\.0\.1:8083;|server kagent-controller.${NS}.svc.cluster.local:8083;|" | \
  kc apply -f - >/dev/null 2>&1 || warn "kagent-ui-config not found (UI may not need the patch on this version)"
kc -n "$NS" rollout restart deploy/kagent-ui >/dev/null 2>&1 || true
kc -n "$NS" rollout status deploy/kagent-ui --timeout=120s >/dev/null 2>&1 || true
ok "kagent-ui proxies /api to the controller"

step "Installing oauth2-proxy (SSO front door -> Keycloak)"
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null 2>&1 || true
helm repo update oauth2-proxy >/dev/null 2>&1
# Reuse the existing cookie secret on rerun so sessions survive; else mint one.
COOKIE_SECRET="$(kc -n "$NS" get secret oauth2-proxy -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "$COOKIE_SECRET" ]] || COOKIE_SECRET="$(openssl rand -hex 16)"
VALS="$(mktemp)"
sed "s|__COOKIE_SECRET__|$COOKIE_SECRET|" "$LAB_ROOT/yaml/ui-auth/oauth2-proxy-keycloak.yaml" > "$VALS"
helm --kube-context "$CTX" upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  -n "$NS" -f "$VALS" --timeout 3m >/dev/null
rm -f "$VALS"
bridge_keycloak_hostalias oauth2-proxy
kc -n "$NS" rollout status deploy/oauth2-proxy --timeout=120s >/dev/null 2>&1 || true
ok "oauth2-proxy installed (issuer ${KEYCLOAK_ISSUER})"

cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  kagent UI SSO ready (Keycloak + oauth2-proxy).
══════════════════════════════════════════════════════════════════
  Browse:  http://localhost:18007   (after ./scripts/open-consoles.sh)
  Login:   alice / alice   (real Keycloak user, field-fte -> Admin)
  No /etc/hosts needed — keycloak.localtest.me resolves to 127.0.0.1.
EOF
