#!/usr/bin/env bash
# 06-kagent-ui-auth.sh — make the kagent Enterprise UI usable on local kind.
#
# The enterprise controller's /api requires an authenticated OIDC session, which
# a real deployment gets from an SSO front door. This stands up that front door
# locally (proven pattern from solo-demos/rugpull-demo):
#
#   1. dex — a static-user OIDC IdP at host.docker.internal:5556 (consistent iss
#            inside the cluster AND in the browser). User: admin@kagent.local/admin.
#   2. re-point the kagent controller's OIDC at dex (+ grant everyone Admin, since
#      dex static users carry no groups claim) and enable the UI.
#   3. patch the kagent-ui pod's nginx upstream to the real controller Service.
#   4. oauth2-proxy in front of kagent-ui — handles the UI's /oauth2/start SSO
#      button, logs in against dex, injects the bearer the controller needs.
#
# Browse the UI at http://localhost:18007 after ./scripts/open-consoles.sh
# (which forwards dex:5556 and oauth2-proxy:18007).
#
# PREREQUISITE (one-time, needs sudo): the browser must resolve host.docker.internal.
#   echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets
require helm

NS=kagent

step "host.docker.internal in /etc/hosts (browser must resolve the dex issuer)"
if grep -q host.docker.internal /etc/hosts 2>/dev/null; then
  ok "/etc/hosts has host.docker.internal"
else
  warn "host.docker.internal is NOT in /etc/hosts — the browser login will fail."
  warn "Run once:  echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts"
fi

step "Installing dex (static-user OIDC IdP)"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo update dex >/dev/null 2>&1
helm --kube-context "$CTX" upgrade --install dex dex/dex \
  -n "$NS" -f "$LAB_ROOT/yaml/ui-auth/dex-values.yaml" --wait --timeout 3m >/dev/null
kc -n "$NS" rollout status deploy/dex --timeout=120s >/dev/null 2>&1 || true
ok "dex installed (issuer http://host.docker.internal:5556)"

# Kind pods can't resolve host.docker.internal (CoreDNS doesn't know it), so the
# controller/oauth2-proxy can't reach the dex issuer by that name. Bridge it with
# a hostAlias on each pod: host.docker.internal -> dex's ClusterIP. The browser
# resolves the same name via /etc/hosts + the open-consoles dex port-forward, so
# the `iss` (http://host.docker.internal:5556) is identical on both sides.
DEX_IP=$(kc -n "$NS" get svc dex -o jsonpath='{.spec.clusterIP}')
[[ -n "$DEX_IP" ]] || die "could not read dex ClusterIP"
patch_hostalias() {
  local dep="$1"
  kc -n "$NS" patch deploy "$dep" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$DEX_IP\",\"hostnames\":[\"host.docker.internal\"]}]}]" >/dev/null 2>&1 || true
}

step "Wiring the kagent controller OIDC at dex"
# The dex static client's secret is the single source of truth — read it back.
DEX_SECRET=$(kc -n "$NS" get secret dex -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d \
  | awk '/staticClients:/{f=1} f&&/secret:/{print $2; exit}')
[[ -n "$DEX_SECRET" ]] || die "could not read dex static-client secret"
kc -n "$NS" create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="$DEX_SECRET" --dry-run=client -o yaml | kc apply -f - >/dev/null
# No --wait here: the controller can't become Ready until its hostAlias is
# patched (it'd fail OIDC discovery on host.docker.internal otherwise), so we
# patch the alias right after, then wait for the rollout.
helm --kube-context "$CTX" upgrade kagent "$KENT_CHART" --version "$KAGENT_ENT_VERSION" \
  -n "$NS" --reuse-values \
  --set oidc.issuer="http://host.docker.internal:5556" \
  --set oidc.clientId="kagent-enterprise" \
  --set oidc.secretRef="kagent-enterprise-oidc-secret" \
  --set oidc.secretKey="clientSecret" \
  --set ui.enabled=true \
  --set-json 'rbac.roleMapping={"roleMapper":"['"'"'global.Admin'"'"']"}' \
  --timeout 6m >/dev/null
patch_hostalias kagent-controller
kc -n "$NS" rollout status deploy/kagent-controller --timeout=180s >/dev/null 2>&1 || true
ok "controller OIDC -> dex (host.docker.internal -> $DEX_IP); everyone -> global.Admin"

step "Patching kagent-ui nginx upstream -> controller Service"
# The bundled UI nginx hard-codes upstream 127.0.0.1:8083 (only correct if the
# controller ran in the UI pod). Without this /api/* returns 502.
kc -n "$NS" get cm kagent-ui-config -o yaml 2>/dev/null | \
  sed "s|server 127\.0\.0\.1:8083;|server kagent-controller.${NS}.svc.cluster.local:8083;|" | \
  kc apply -f - >/dev/null 2>&1 || warn "kagent-ui-config not found (UI may not need the patch on this version)"
kc -n "$NS" rollout restart deploy/kagent-ui >/dev/null 2>&1 || true
kc -n "$NS" rollout status deploy/kagent-ui --timeout=120s >/dev/null 2>&1 || true

step "Installing oauth2-proxy (SSO front door for the UI)"
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null 2>&1 || true
helm repo update oauth2-proxy >/dev/null 2>&1
COOKIE_SECRET=$(kc -n "$NS" get secret oauth2-proxy -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d || true)
[[ -n "$COOKIE_SECRET" ]] || COOKIE_SECRET=$(openssl rand -hex 16)
VALS=$(mktemp)
sed -e "s|__DEX_CLIENT_SECRET__|$DEX_SECRET|" -e "s|__COOKIE_SECRET__|$COOKIE_SECRET|" \
  "$LAB_ROOT/yaml/ui-auth/oauth2-proxy-values.template.yaml" > "$VALS"
helm --kube-context "$CTX" upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  -n "$NS" -f "$VALS" --timeout 3m >/dev/null
rm -f "$VALS"
patch_hostalias oauth2-proxy   # so it too can reach the dex issuer in-cluster
kc -n "$NS" rollout status deploy/oauth2-proxy --timeout=120s >/dev/null 2>&1 || true
# The chart munges approval-prompt='auto' to empty; set it directly so dex's
# skipApprovalScreen path is taken.
kc -n "$NS" get deploy oauth2-proxy -o json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); c=d['spec']['template']['spec']['containers'][0]; c['args']=[a for a in c.get('args',[]) if not a.startswith('--approval-prompt')]+['--approval-prompt=auto']; print(json.dumps(d))" | \
  kc apply -f - >/dev/null 2>&1 || true
kc -n "$NS" rollout status deploy/oauth2-proxy --timeout=120s >/dev/null 2>&1 || true
ok "oauth2-proxy installed"

cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  kagent UI auth ready (dex + oauth2-proxy).
══════════════════════════════════════════════════════════════════
  Browse:  http://localhost:18007   (after ./scripts/open-consoles.sh)
  Login:   admin@kagent.local / admin
  One-time, if not done:  echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts
EOF
