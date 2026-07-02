#!/usr/bin/env bash
# Generate metered traffic as two tenants (tesco, acme). Assumes port-forward on :8080.
BASE="${BASE:-http://localhost:8080}"
for i in $(seq 1 "${1:-5}"); do
  curl -s -o /dev/null -H 'x-customer-id: tesco' "$BASE/products/99"
  curl -s -o /dev/null -H 'x-customer-id: tesco' "$BASE/basket" -X POST
  curl -s -o /dev/null -H 'x-customer-id: acme'  "$BASE/products/42"
done
echo "sent $(( ${1:-5} * 3 )) requests (tesco x2/iter, acme x1/iter)"
