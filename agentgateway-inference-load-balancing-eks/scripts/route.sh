#!/usr/bin/env bash
# Flip the gateway between the two backends the lab compares.
#
#   ./scripts/route.sh service   backendRef is the Kubernetes Service: round-robin
#   ./scripts/route.sh pool      backendRef is the InferencePool: the Endpoint Picker decides
#   ./scripts/route.sh           show which is in force
#
# Both files define the SAME HTTPRoute name, so applying one replaces the other. There
# is never a moment with two routes fighting over the same path.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

case "${1:-show}" in
  service)
    kc apply -f "$LAB_ROOT/yaml/10-httproute-service.yaml" >/dev/null
    ok "route -> Service vllm (round-robin)"
    ;;
  pool)
    kc apply -f "$LAB_ROOT/yaml/11-httproute-pool.yaml" >/dev/null
    ok "route -> InferencePool $POOL_RELEASE (Endpoint Picker)"
    ;;
  show)
    kc -n "$NS" get httproute llm-route \
      -o jsonpath='{range .spec.rules[*].backendRefs[*]}{.group}/{.kind}/{.name}{"\n"}{end}'
    exit 0
    ;;
  *) die "usage: $0 {service|pool|show}" ;;
esac

# A route that is Accepted but whose backend did not resolve still serves traffic, to
# whatever the previous config pointed at, so read the resolution condition rather than
# assuming the apply was the end of it.
sleep 2
kc -n "$NS" get httproute llm-route \
  -o jsonpath='{range .status.parents[*]}{.conditions[?(@.type=="ResolvedRefs")].status} {.conditions[?(@.type=="ResolvedRefs")].message}{"\n"}{end}' \
  | sed 's/^/    ResolvedRefs: /' >&2
