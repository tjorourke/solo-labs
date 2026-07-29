#!/usr/bin/env bash
# certs.sh — the certificate inventory: for each workload, which data plane it
# is on and what key algorithm its live certificate uses, read from the actual
# serving state (Envoy SDS for sidecars, ztunnel for ambient), not from
# Kubernetes objects. This is the table that proves the migration did what it
# claimed: RSA where nothing moved, EC only where ambient took over.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require istioctl; require jq; require openssl

row() { printf '%-11s %-10s %-9s %-16s %-22s %s\n' "$@"; }

inventory_sidecar() { # <ns> <deploy>
  local pem algo serial
  pem="$(sidecar_leaf_pem "$1" "$2" || true)"
  if [[ -z "$pem" ]]; then row "$1" "$2" "sidecar" "-" "no cert" "-"; return; fi
  algo="$(printf '%s' "$pem" | pem_key_algo)"
  serial="$(printf '%s' "$pem" | pem_serial)"
  row "$1" "$2" "sidecar" "$algo" "${serial:0:20}…" "$(printf '%s' "$pem" | pem_issuer | sed 's/^issuer=//')"
}

inventory_ambient() { # <ns> <sa>
  local pem algo serial
  pem="$(ztunnel_leaf_pem "$1" "$2" || true)"
  if [[ -z "$pem" || "$pem" != *BEGIN* ]]; then row "$1" "$2" "ambient" "-" "no cert" "-"; return; fi
  algo="$(printf '%s' "$pem" | pem_key_algo)"
  serial="$(printf '%s' "$pem" | pem_serial)"
  row "$1" "$2" "ambient" "$algo" "${serial:0:20}…" "$(printf '%s' "$pem" | pem_issuer | sed 's/^issuer=//')"
}

ns_mode() { # ambient | sidecar, from the namespace label
  kc get ns "$1" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null \
    | grep -q ambient && echo ambient || echo sidecar
}

echo
row "NAMESPACE" "WORKLOAD" "DATAPLANE" "KEY ALGORITHM" "SERIAL" "ISSUER"
for ns in "$NS_STAY" "$NS_MOVE"; do
  mode="$(ns_mode "$ns")"
  for d in httpbin client fortio; do
    kc -n "$ns" get deploy "$d" >/dev/null 2>&1 || continue
    if [[ "$mode" == "ambient" ]]; then
      inventory_ambient "$ns" "$d"
    else
      inventory_sidecar "$ns" "$d"
    fi
  done
done
if kc get ns "$NS_PRE" >/dev/null 2>&1; then
  inventory_ambient "$NS_PRE" httpbin
fi
echo
