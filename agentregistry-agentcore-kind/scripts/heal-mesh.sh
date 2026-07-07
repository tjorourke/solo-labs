#!/usr/bin/env bash
# heal-mesh.sh — SOURCE this; it defines _heal_mesh_certs (no side effects on source).
#
# On a kind cluster reused for days, the enterprise-agentgateway XDS control-plane
# serving cert (CN=agw-xds-server, ~24h TTL, minted in-memory at pod start) stops
# rotating and expires. Every data-plane proxy that pulls config from :9978 — the
# ingress `agentgateway-proxy` AND the kagent waypoints — then rejects the peer with
# "invalid peer certificate: certificate expired", never goes Ready, and both the
# demo and the registry ingress (agentregistry.localtest.me) start 500ing. There is
# no TTL knob for this cert in 2026.5.x, so we detect the symptom and bounce the XDS
# servers + data planes to re-mint / re-fetch fresh certs.
#
# No-op (fast) on a healthy cluster. Set SKIP_MESH_HEAL=1 to skip. Sourced by
# connect.sh (every notebook session, before any registry call) and reset.sh (so its
# arctl cleanup through the ingress doesn't fail on an expired cert on a stale cluster).
_heal_mesh_certs() {
  local ctx="kind-${CLUSTER_NAME:-agentcore-demo}" dp ns res r bad=0
  kubectl --context "$ctx" cluster-info >/dev/null 2>&1 || return 0   # cluster not up yet
  for dp in agentgateway-system/agentgateway-proxy \
            kagent/agent-agentdemo-waypoint \
            kagent/mcpserver-my-mcp-waypoint; do
    ns="${dp%%/*}"; res="deploy/${dp#*/}"
    kubectl --context "$ctx" -n "$ns" get "$res" >/dev/null 2>&1 || continue
    kubectl --context "$ctx" -n "$ns" logs "$res" --tail=40 2>/dev/null | grep -q "certificate expired" && bad=1
    r=$(kubectl --context "$ctx" -n "$ns" get "$res" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [ "${r:-0}" -ge 1 ] 2>/dev/null || bad=1
  done
  if [ "$bad" != 1 ]; then echo "mesh certs · ok"; return 0; fi
  echo "mesh certs · expired xds cert detected, healing (this takes ~1-2 min) ..."
  kubectl --context "$ctx" -n istio-system        rollout restart deploy/istiod-gloo ds/ztunnel    >/dev/null 2>&1
  kubectl --context "$ctx" -n agentgateway-system rollout restart deploy/enterprise-agentgateway   >/dev/null 2>&1
  kubectl --context "$ctx" -n agentgateway-system rollout status  deploy/enterprise-agentgateway --timeout=120s >/dev/null 2>&1
  # bounce every data plane so it re-fetches a fresh cert from the restarted xds server
  kubectl --context "$ctx" -n agentgateway-system rollout restart deploy --all                     >/dev/null 2>&1
  for res in agent-agentdemo-waypoint mcpserver-my-mcp-waypoint; do
    kubectl --context "$ctx" -n kagent get deploy "$res" >/dev/null 2>&1 &&
      kubectl --context "$ctx" -n kagent rollout restart "deploy/$res" >/dev/null 2>&1
  done
  kubectl --context "$ctx" -n agentgateway-system rollout status deploy/agentgateway-proxy --timeout=120s >/dev/null 2>&1
  echo "mesh certs · healed"
}
