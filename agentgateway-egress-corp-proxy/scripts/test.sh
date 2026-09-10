#!/usr/bin/env bash
# test.sh — assert every egress shape, including the four that must fail.
#
# A lab that only shows the working case proves nothing. Two of the controls
# here caught real false positives while this was being written:
#   - the authenticating proxy was not actually authenticating, because the
#     Squid image's own conf.d/debian.conf allows localnet and loads first
#   - a backend whose tunnel is dropped still returns 200, because the direct
#     route to the destination also works
# That is why every positive has a negative next to it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PASS=0; FAIL=0

hit() { curl -s -o "/tmp/egress-body.$$" -w '%{http_code}' --max-time 20 "${GW_URL}$1" 2>/dev/null || echo 000; }
body() { cat "/tmp/egress-body.$$" 2>/dev/null; }

expect_ok() {
  local path="$1" label="$2" code
  code="$(hit "$path")"
  if [[ "$code" == "200" ]] && body | grep -q 'acme-external'; then
    ok "$label — 200 from the destination"; PASS=$((PASS+1))
  else
    warn "$label — expected 200, got $code: $(body | head -c 160)"; FAIL=$((FAIL+1))
  fi
}

expect_fail() {
  local path="$1" label="$2" code
  code="$(hit "$path")"
  if [[ "$code" == "200" ]]; then
    warn "$label — expected a failure, got 200: $(body | head -c 160)"; FAIL=$((FAIL+1))
  else
    ok "$label — failed as intended ($code)"; PASS=$((PASS+1))
  fi
}

# agentgateway pools upstream connections, and a pooled tunnel outlives a
# config change. Start from a cold data plane or the run measures the previous
# configuration. This is worth knowing outside the lab too: after editing a
# tunnel or TLS policy, restart the gateway before deciding it did not work.
step "Restarting the gateway so no pooled tunnel survives from a previous run"
kc -n "$AGW_NS" rollout restart deploy/"$GATEWAY_NAME" >/dev/null 2>&1 || true
kc -n "$AGW_NS" rollout status deploy/"$GATEWAY_NAME" --timeout=180s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do [[ "$(hit /direct)" != "000" ]] && break; sleep 2; done

step "Baseline"
expect_ok   /direct              "direct, no proxy, destination CA"

step "Plain CONNECT tunnel"
expect_ok   /tunnel              "tunnel via Squid (backendRef), destination CA"
expect_ok   /tunnel-url          "tunnel via Squid (url form, mode: Connect)"

step "TLS-inspecting proxy"
expect_fail /inspect-broken      "inspecting proxy, destination CA — the broken state"
expect_ok   /inspect             "inspecting proxy, corporate CA from a ConfigMap"
expect_ok   /inspect-secret      "inspecting proxy, corporate CA from a Secret"

step "Proxy that needs credentials"
expect_fail /proxy-auth-missing  "no credentials configured — the control"
expect_ok   /proxy-auth          "Proxy-Authorization on the CONNECT"

step "TLS on the hop to the proxy"
expect_ok   /proxy-tls           "TLS to the proxy, tunnel inside it"

step "Destination the gateway cannot resolve"
expect_fail /airgap-direct       "unresolvable destination, no proxy — the control"
expect_ok   /airgap              "unresolvable destination, resolved by the proxy"

# Squid writes a tunnel's access-log line when the tunnel CLOSES. The gateway
# holds them open in its pool, so they have to be flushed before the log can be
# read as evidence.
step "Evidence from the proxies"
kc -n "$AGW_NS" rollout restart deploy/"$GATEWAY_NAME" >/dev/null 2>&1 || true
kc -n "$AGW_NS" rollout status deploy/"$GATEWAY_NAME" --timeout=180s >/dev/null 2>&1 || true
# rollout status returns when the NEW pod is ready; the old one is still
# draining, and the tunnels are logged only once it has actually gone.
log "waiting for the old gateway pod to finish draining"
for _ in $(seq 1 60); do
  [[ "$(kc -n "$AGW_NS" get pods -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "1" ]] && break
  sleep 2
done

# Poll rather than read once: how long a drained tunnel takes to reach the
# access log depends on the shutdown grace period.
#
# The log is captured into a variable before grepping, on purpose. Piping
# kubectl straight into `grep -q` under `set -o pipefail` reports a FAILURE on
# a successful match: grep exits as soon as it matches, kubectl dies on SIGPIPE,
# and pipefail takes the last non-zero status. That produced three phantom
# failures here before it was spotted.
check_log() {
  local deploy="$1" pattern="$2" label="$3" out
  for _ in $(seq 1 30); do
    out="$(kc -n "$EGRESS_NS" logs "deploy/$deploy" 2>/dev/null || true)"
    if grep -qE "$pattern" <<<"$out"; then
      ok "$label"; PASS=$((PASS+1)); return
    fi
    sleep 2
  done
  warn "$label — not found in the $deploy log"; FAIL=$((FAIL+1))
}

check_log squid      'TCP_TUNNEL/200 .* CONNECT api\.upstream'          "Squid tunnelled the destination"
check_log squid      'TCP_TUNNEL/200 .* CONNECT jwks\.acme-external'    "Squid resolved and tunnelled the air-gapped name"
check_log squid-auth 'TCP_DENIED/407'                                   "Squid rejected the uncredentialled CONNECT"
check_log squid-auth "TCP_TUNNEL/200 .* CONNECT .* ${PROXY_USER} "      "Squid logged ${PROXY_USER} on the authenticated CONNECT"
check_log mitm       'api\.upstream'                                    "the inspecting proxy saw the request"

rm -f "/tmp/egress-body.$$"
step "Result"
if [[ $FAIL -eq 0 ]]; then
  ok "PASS — $PASS checks"; echo "PASS"
else
  warn "$FAIL of $((PASS+FAIL)) checks failed"; echo "FAIL"; exit 1
fi
