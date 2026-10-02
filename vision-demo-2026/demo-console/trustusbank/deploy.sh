#!/usr/bin/env bash
# deploy.sh — the TrustUsBank finance agents, on Gemma, in Berlin.
#
#   ./trustusbank/deploy.sh              build, push, deploy everything
#   SKIP_BUILD=1 ./trustusbank/deploy.sh reuse the images already pushed
#   ./trustusbank/deploy.sh --delete     remove the agents, records and servers
#
# What it creates, per finance domain (payments, compliance, credit, gdpr):
#
#   ns mcp          bank-<domain> Deployment + Service: the core-banking MCP
#                   server for that domain, mock data, one image for all four
#   agentgateway    an MCP backend, reached only through the shared mcp-waypoint: the
#                   Service is labelled istio.io/use-waypoint and a mesh HTTPRoute
#                   sends it to the backend. Agents dial bank-<domain>.mcp.svc:3000/mcp;
#                   the waypoint knows them by ServiceAccount and the <backend>-per-agent
#                   policy (the lab's 92-mcp-lockdown.sh, yaml/mcp-mesh/grants.json)
#                   allows each one only its own tools. There is no edge route.
#   AgentRegistry   an MCPServer record (the approved tool server), an Agent
#                   record (the image) and a Deployment, which makes the registry
#                   push the agent onto kagent. Nobody kubectl-applies an agent.
#
# The agents reach Gemma 3 27B through llm.agentic.eu0.internal, the gateway route
# straight to the H100 in ns model: finance never takes the VSR path to Gemini.
#
# Drives the google-sov lab's lib.sh, so the Berlin kubeconfig, universe and
# Artifact Registry come from there. GCD_LAB overrides where that lab lives.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCD_LAB="${GCD_LAB:-$HOME/code/google-sov/poc/2026-09-agentic-platform}"
# shellcheck source=/dev/null
source "$GCD_LAB/scripts/lib.sh"
load_env
assert_universe
kube_context >/dev/null 2>&1 || true
assert_kube_reachable
require docker kubectl python3 gcloud

MCP_NS="${MCP_NS:-mcp}"
AGW_NS=agentgateway-system
GW=agentgateway-proxy
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
AR_NS=agentregistry-system
TAG="${TRUSTUSBANK_TAG:-0.1.6}"
MCP_IMAGE="${AR_PREFIX:?}/trustusbank-mcp:${TAG}"
AGENT_IMAGE="${AR_PREFIX}/trustusbank-agent:${TRUSTUSBANK_AGENT_TAG:-0.1.8}"
MODEL_BASE_URL="${TRUSTUSBANK_MODEL_URL:-http://llm.${BASE_DOMAIN}/v1}"
DOMAINS=(payments compliance credit gdpr)

# shellcheck source=/dev/null
source "$GCD_LAB/scripts/55-arctl-connect.sh"
[[ "${_ARCTL_RC:-1}" -eq 0 ]] || die "could not connect arctl to AgentRegistry"

# Render every AgentRegistry record from agents.json, so the console and this
# script describe the same four agents. kind=mcp|agent|deployment.
render() {
  python3 - "$HERE/agents.json" "$1" <<PY
import json, sys
agents = json.load(open(sys.argv[1])); kind = sys.argv[2]
def y(v): return json.dumps(v)   # JSON is YAML, and quotes every prompt safely
docs = []
for a in agents:
    d, n = a["domain"], a["name"]
    url = "http://bank-%s.${MCP_NS}.svc.cluster.local:3000/mcp" % d
    if kind == "mcp":
        docs.append(f"""apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: trustusbank-{d}-tools
spec:
  title: {y("TrustUsBank " + d + " tools")}
  description: {y("Core-banking " + d + " tools, mock data. At " + url + ", behind the mcp-waypoint")}
  remote:
    type: http
    url: {url}""")
    elif kind == "agent":
        docs.append(f"""apiVersion: ar.dev/v1alpha1
kind: Agent
metadata:
  name: {n}
spec:
  description: {y(a["description"])}
  modelName: gemma-3-27b-it
  modelProvider: openai
  source:
    image: ${AGENT_IMAGE}
  mcpServers:
    - kind: MCPServer
      name: trustusbank-{d}-tools""")
    else:
        mcp = json.dumps([{"name": "trustusbank-%s-tools" % d, "type": "remote", "url": url}])
        docs.append(f"""apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: {n}-kagent
spec:
  targetRef:  {{ kind: Agent,   name: {n} }}
  runtimeRef: {{ kind: Runtime, name: kubernetes-default }}
  env:
    MODEL_NAME: gemma-3-27b-it
    MODEL_BASE_URL: ${MODEL_BASE_URL}
    MODEL_API_KEY: sovereign-local-noauth
    MCP_SERVERS_CONFIG: {y(mcp)}
    MCP_TERMINATE_ON_CLOSE: "false"
    SYSTEM_MESSAGE: {y(a["system"])}
    AGENT_DESCRIPTION: {y(a["description"])}
    ADK_AGENT_NAME: {a["agent_name"]}
    OTEL_SERVICE_NAME: {n}""")
print("\n---\n".join(docs))
PY
}

if [[ "${1:-}" == "--delete" ]]; then
  step "removing the TrustUsBank agents"
  for d in "${DOMAINS[@]}"; do
    arctl delete deployment "trustusbank-$d-kagent" >/dev/null 2>&1 || true
    arctl delete agent "trustusbank-$d" >/dev/null 2>&1 || true
    arctl delete mcpserver "trustusbank-$d-tools" >/dev/null 2>&1 || true
    kc -n "$MCP_NS" delete deploy,svc "bank-$d" --ignore-not-found >/dev/null
    kc -n "$MCP_NS" delete agentgatewaybackend "bank-$d-mcp" --ignore-not-found >/dev/null
    kc -n "$MCP_NS" delete httproute "bank-$d-mcp" "bank-$d-mesh" --ignore-not-found >/dev/null
  done
  ok "removed"
  exit 0
fi

# ── 1. images ───────────────────────────────────────────────────────────────
step "build and push the MCP and agent images (linux/amd64: GCD has no Arm)"
ar_docker_login "${AR_HOST:?}"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  log "SKIP_BUILD=1, reusing $MCP_IMAGE and $AGENT_IMAGE"
else
  docker build --platform linux/amd64 -t "$MCP_IMAGE" "$HERE/mcp" || die "MCP image build failed"
  docker push "$MCP_IMAGE" || die "MCP image push failed"
  docker build --platform linux/amd64 -t "$AGENT_IMAGE" "$HERE/agent-runtime" || die "agent image build failed"
  docker push "$AGENT_IMAGE" || die "agent image push failed"
  ok "pushed $MCP_IMAGE and $AGENT_IMAGE"
fi

# ── 2. the four MCP servers, each behind the mcp-waypoint ───────────────────
step "core-banking MCP servers in ns $MCP_NS"
kc create ns "$MCP_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
# Nodes cannot pull from the GCD registry host on their own; see 90-mcp-agent.sh.
kc -n "$MCP_NS" create secret docker-registry ar-pull \
  --docker-server="$AR_HOST" --docker-username=oauth2accesstoken \
  --docker-password="$(gcloud auth print-access-token)" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
for d in "${DOMAINS[@]}"; do
  kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bank-${d}
  labels: { app: bank-${d}, company: trustusbank }
spec:
  replicas: 1
  selector: { matchLabels: { app: bank-${d} } }
  template:
    metadata: { labels: { app: bank-${d}, company: trustusbank } }
    spec:
      imagePullSecrets: [{ name: ar-pull }]
      containers:
        - name: server
          image: ${MCP_IMAGE}
          imagePullPolicy: Always
          env: [{ name: DOMAIN, value: ${d} }]
          ports: [{ containerPort: 3000, name: http }]
          readinessProbe: { tcpSocket: { port: 3000 }, periodSeconds: 5 }
          # Autopilot requires requests on every container.
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: bank-${d}
  labels: { company: trustusbank, istio.io/use-waypoint: mcp-waypoint, mcp-lockdown/service: bank-${d} }
spec:
  selector: { app: bank-${d} }
  ports: [{ name: http, port: 3000, targetPort: 3000, appProtocol: kgateway.dev/mcp }]
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: bank-${d}-mcp
spec:
  mcp:
    targets:
      - name: bank-${d}
        selector:
          services:
            matchLabels: { mcp-lockdown/service: bank-${d} }
---
# The mesh route: a call to the Service, steered to the waypoint by ztunnel, goes
# to the backend. Nothing on the edge gateway points here.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bank-${d}-mesh
  labels: { company: trustusbank }
spec:
  parentRefs: [{ group: "", kind: Service, name: bank-${d} }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: bank-${d}-mcp
YAML
done
for d in "${DOMAINS[@]}"; do
  # An edge route from an earlier deploy would be a way round the waypoint.
  kc -n "$MCP_NS" delete httproute "bank-$d-mcp" --ignore-not-found >/dev/null
  kc -n "$MCP_NS" rollout status "deploy/bank-$d" --timeout=180s || die "bank-$d did not start"
done
ok "4 MCP servers up at bank-{${DOMAINS[*]// /,}}.${MCP_NS}.svc:3000/mcp, behind mcp-waypoint"

if kc -n "$MCP_NS" get deploy mcp-catalog >/dev/null 2>&1; then
step "list each server's tools through the waypoint, as mcp-catalog (the list-only identity)"
kc -n "$MCP_NS" exec -i deploy/mcp-catalog -- python3 - "$MCP_NS" "${DOMAINS[@]}" <<'PY' \
  || die "the waypoint does not serve the bank tools to mcp-catalog"
import json, sys, urllib.request
from pathlib import Path
ns, domains = sys.argv[1], sys.argv[2:]
H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
def post(url, body, sid=None):
    h = dict(H, **({"mcp-session-id": sid} if sid else {}))
    h["Authorization"] = "Bearer " + Path("/var/run/secrets/mcp/token").read_text().strip()
    r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), h), timeout=20)
    raw = r.read().decode()
    # The gateway answers in SSE framing: take the data line.
    data = next((l[5:] for l in raw.splitlines() if l.startswith("data:")), raw)
    return r.headers.get("mcp-session-id"), (json.loads(data) if data.strip() else {})
for d in domains:
    url = "http://bank-%s.%s.svc.cluster.local:3000/mcp" % (d, ns)
    sid, _ = post(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "deploy", "version": "1"}}})
    post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, r = post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
    print("  %-11s %s" % (d, ", ".join(t["name"] for t in r["result"]["tools"])))
PY
else
  warn "no mcp/mcp-catalog yet: run the lab's scripts/92-mcp-lockdown.sh after this deploy"
fi

# ── 3. AgentRegistry: approve the tools, catalogue the agents, push them ────
step "catalogue the tool servers and the agents in AgentRegistry"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render mcp > "$TMP/mcp.yaml"; render agent > "$TMP/agent.yaml"; render deployment > "$TMP/deploy.yaml"
arctl apply -f "$TMP/mcp.yaml"   || die "could not catalogue the MCP servers"
arctl apply -f "$TMP/agent.yaml" || die "could not catalogue the agents"

step "let AgentRegistry push the agents onto kagent"
for d in "${DOMAINS[@]}"; do
  # A record whose workload is gone is Cloud SQL state surviving a rebuild, and one
  # whose RemoteMCPServer still names an old URL was pushed before this layout:
  # recreate both, since AgentRegistry renders the RemoteMCPServer only on create.
  url="$(kc -n "$AR_NS" get remotemcpserver -o json 2>/dev/null | python3 -c '
import json, sys
d = sys.argv[1]
print(next((r["spec"]["url"] for r in json.load(sys.stdin)["items"]
            if r["metadata"]["name"].startswith(f"trustusbank-{d}-tools-trustusbank-")), ""))' "$d")"
  if arctl get deployments 2>/dev/null | grep -q "trustusbank-$d-kagent" \
     && { ! kc -n "$AR_NS" get deploy -o name 2>/dev/null | grep -q "trustusbank-$d" \
          || [[ -n "$url" && "$url" != *"bank-$d.$MCP_NS.svc"* ]]; }; then
    arctl delete deployment "trustusbank-$d-kagent" >/dev/null 2>&1 || true
    sleep 2
  fi
done
arctl apply -f "$TMP/deploy.yaml" || die "could not create the AR Deployments"

for d in "${DOMAINS[@]}"; do
  dep=""
  for _ in $(seq 1 60); do
    dep="$(kc -n "$AR_NS" get deploy -o name 2>/dev/null | grep -m1 "trustusbank-$d" || true)"
    [[ -n "$dep" ]] && break
    sleep 5
  done
  [[ -n "$dep" ]] || die "AgentRegistry created no workload for trustusbank-$d (arctl get deployments -o yaml)"
  kc -n "$AR_NS" rollout restart "$dep" >/dev/null 2>&1 || true   # pick up a re-pushed :$TAG
  kc -n "$AR_NS" rollout status "$dep" --timeout=300s || die "trustusbank-$d did not become ready"
done

step "grant each agent its tools at the waypoint, by ServiceAccount"
# The SA names only exist now that AgentRegistry has created the Deployments.
KUBE_CONTEXT="$(kube_context)" python3 "$GCD_LAB/scripts/mcp_policies.py" --apply \
  || die "could not apply the per-agent MCP policies"
ok "one <agent>--<backend> policy per agent, naming its new ServiceAccount"
python3 "$GCD_LAB/scripts/mcp_security.py" agents || die "agent identity reconciliation failed"
python3 "$GCD_LAB/scripts/mcp_security.py" servers || die "MCP enforcement reconciliation failed"
python3 "$GCD_LAB/scripts/mcp_security.py" discovery || die "MCP discovery identity reconciliation failed"

step "what the registry created"
kc -n "$AR_NS" get agents.kagent.dev | grep -E 'NAME|trustusbank' || true
ok "TrustUsBank agents deployed by AgentRegistry onto kagent, on Gemma, in Berlin"
