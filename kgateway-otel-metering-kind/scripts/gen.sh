#!/usr/bin/env bash
# Generate metered traffic as two tenants (tesco, sainsburys). Assumes port-forward on :8080.
BASE="${BASE:-http://localhost:8080}"
for i in $(seq 1 "${1:-5}"); do
  curl -s -o /dev/null -H 'x-customer-id: tesco'      "$BASE/products/99"
  curl -s -o /dev/null -H 'x-customer-id: tesco'      "$BASE/basket" -X POST
  curl -s -o /dev/null -H 'x-customer-id: sainsburys' "$BASE/products/12"
  curl -s -o /dev/null -H 'x-customer-id: sainsburys' "$BASE/checkout" -X POST
done
echo "sent $(( ${1:-5} * 4 )) requests (tesco x2/iter, sainsburys x2/iter)"
