#!/usr/bin/env bash
# deploy.sh — TrustUsBank agent SDLC: a banking app, two environments, a PM and an
# engineer agent on Gemma, all in Berlin.
#
#   ./trustusbank-sdlc/deploy.sh              build, push, deploy everything
#   SKIP_BUILD=1 ./trustusbank-sdlc/deploy.sh reuse the MCP image already pushed
#   ./trustusbank-sdlc/deploy.sh --delete     remove it all (the GitHub repo is left alone)
#
# What it creates:
#
#   ns trustusbank-staging, trustusbank-prod
#                   Deployment + Service "payments": the online-banking app built from
#                   github.com/tjorourke/trustusbank-payments, routed by agentgateway at
#                   staging.payments.agentic.eu0.internal and payments.agentic.eu0.internal.
#                   A re-run never resets the image: the console's approve/deny flow owns it.
#   ns mcp          sdlc-pm and sdlc-dev: small GitHub MCP servers (github_mcp.py) behind
#                   agentgateway at mcp.agentic.eu0.internal/mcp/sdlc-{pm,dev}. Gemma has an
#                   8k context, so these answer in a few hundred tokens, not whole payloads.
#   AgentRegistry   MCPServer and Agent records for trustusbank-pm-agent and trustusbank-dev-agent: the catalogue.
#   kagent          Agents named trustusbank-pm-agent and trustusbank-dev-agent in ns agentregistry-system,
#                   applied directly so kagent, its UI and traces show those names.
#
# The GitHub token is TRUSTUSBANK_GITHUB_TOKEN, else GITHUB_PORTLAB_TOKEN from
# ../secrets.env. It goes into a Secret and is never printed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCD_LAB="${GCD_LAB:-$HOME/code/google-sov/poc/2026-09-agentic-platform}"
# shellcheck source=/dev/null
source "$GCD_LAB/scripts/lib.sh"
load_env
assert_universe
kube_context >/dev/null 2>&1 || true
assert_kube_reachable
require docker kubectl python3 gcloud git

MCP_NS="${MCP_NS:-mcp}"
AGW_NS=agentgateway-system
GW=agentgateway-proxy
BASE_DOMAIN="${BASE_DOMAIN:-agentic.eu0.internal}"
AR_NS=agentregistry-system
REPO="${TUB_REPO:-tjorourke/trustusbank-payments}"
APP_IMAGE="${AR_PREFIX:?}/trustusbank-payments"
TAG="${TUB_SDLC_TAG:-0.2.0}"
MCP_IMAGE="${AR_PREFIX}/trustusbank-sdlc-mcp:${TAG}"
# Built from trustusbank/agent-runtime (the same runtime as every TrustUsBank agent), under
# its own name so this demo never repoints or races the banking agents' image. It must
# track kagent's version: an older kagent-adk fails against a newer controller.
AGENT_IMAGE="${TUB_AGENT_IMAGE:-${AR_PREFIX}/trustusbank-agent:0.1.8}"
MODEL_BASE_URL="${TRUSTUSBANK_MODEL_URL:-http://llm.${BASE_DOMAIN}/v1}"
ROLES=(pm dev)
NS_staging=trustusbank-staging; NS_prod=trustusbank-prod
HOST_staging="staging.payments.${BASE_DOMAIN}"; HOST_prod="payments.${BASE_DOMAIN}"
ENV_staging=staging; ENV_prod=production
ns_of()   { eval "printf %s \"\$NS_$1\""; }     # macOS bash 3.2: no associative arrays
host_of() { eval "printf %s \"\$HOST_$1\""; }

# shellcheck source=/dev/null
source "$GCD_LAB/scripts/55-arctl-connect.sh"
[[ "${_ARCTL_RC:-1}" -eq 0 ]] || die "could not connect arctl to AgentRegistry"

render() {
  python3 - "$HERE/agents.json" "$1" <<PY
import json, sys
agents = json.load(open(sys.argv[1])); kind = sys.argv[2]
def y(v): return json.dumps(v)
docs = []
for a in agents:
    r, n = a["role"], a["name"]
    url = "http://sdlc-%s.${MCP_NS}.svc.cluster.local:3000/mcp" % r
    if kind == "mcp":
        docs.append(f"""apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: {n}-tools
spec:
  title: {y("TrustUsBank SDLC " + r + " GitHub tools")}
  description: {y("GitHub tools for ${REPO}, sized for Gemma. Reached only through agentgateway at " + url)}
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
      name: {n}-tools""")
    else:
        # The kagent Agent itself, applied by kubectl under the agent's own name. An AR
        # Deployment would name it <agent>-latest-<deployment> cut to 36 characters,
        # and kagent shows that name in its UI, its ADK app name and every trace.
        mcp = json.dumps([{"name": n + "-tools", "type": "remote", "url": url}])
        env = {"AGENT_DESCRIPTION": a["description"], "AGENT_NAME": n, "KAGENT_NAME": n, "ADK_AGENT_NAME": n,
               "KAGENT_NAMESPACE": "${AR_NS}", "KAGENT_URL": "http://kagent-controller.kagent.svc.cluster.local",
               "MCP_SERVERS_CONFIG": mcp, "MCP_TERMINATE_ON_CLOSE": "false",
               "MODEL_API_KEY": "sovereign-local-noauth", "MODEL_BASE_URL": "${MODEL_BASE_URL}",
               "MODEL_NAME": "gemma-3-27b-it", "MODEL_PROVIDER": "openai",
               "OTEL_SERVICE_NAME": n, "SYSTEM_MESSAGE": a["system"]}
        envs = "\n".join(f"        - {{ name: {k}, value: {y(v)} }}" for k, v in env.items())
        docs.append(f"""apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: {n}
  namespace: ${AR_NS}
  labels: {{ company: trustusbank, app.kubernetes.io/part-of: trustusbank-sdlc }}
spec:
  type: BYO
  description: {y(a["title"] if "title" in a else a["description"])}
  byo:
    deployment:
      image: ${AGENT_IMAGE}
      env:
{envs}""")
print("\n---\n".join(docs))
PY
}

pull_secret() {
  # Nodes cannot pull from the GCD registry host on their own; see 90-mcp-agent.sh.
  kc -n "$1" create secret docker-registry ar-pull \
    --docker-server="$AR_HOST" --docker-username=oauth2accesstoken \
    --docker-password="$(gcloud auth print-access-token)" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
}

AGENT_NAMES=(trustusbank-pm-agent trustusbank-dev-agent)
# Renamed back from tub-sdlc-* on 2026-10-02: every TrustUsBank agent is trustusbank-*.
OLD_NAMES=(tub-sdlc-pm tub-sdlc-dev)

remove_agents() {
  for a in "$@"; do
    arctl delete deployment "$a-kagent" >/dev/null 2>&1 || true
    kc -n "$AR_NS" delete agents.kagent.dev "$a" --ignore-not-found >/dev/null
    arctl delete agent "$a" >/dev/null 2>&1 || true
    arctl delete mcpserver "$a-tools" >/dev/null 2>&1 || true
  done
}

if [[ "${1:-}" == "--delete" ]]; then
  step "removing the TrustUsBank SDLC demo"
  remove_agents "${AGENT_NAMES[@]}" "${OLD_NAMES[@]}"
  for r in "${ROLES[@]}"; do
    kc -n "$MCP_NS" delete deploy,svc "sdlc-$r" --ignore-not-found >/dev/null
    kc -n "$MCP_NS" delete agentgatewaybackend,httproute "sdlc-$r-mcp" --ignore-not-found >/dev/null
  done
  kc -n "$MCP_NS" delete secret tub-sdlc-github --ignore-not-found >/dev/null
  kc delete ns "$NS_staging" "$NS_prod" --ignore-not-found >/dev/null
  ok "removed"
  exit 0
fi

# ── 1. images ───────────────────────────────────────────────────────────────
step "build and push the app and MCP images (linux/amd64: GCD has no Arm)"
ar_docker_login "${AR_HOST:?}"
SHA="$(git ls-remote "https://github.com/$REPO.git" refs/heads/main | cut -c1-12)"
[[ -n "$SHA" ]] || die "cannot read $REPO's main branch (gh auth status?)"
SEED="$APP_IMAGE:$SHA-$(date +%s)"
need_app=0
for e in staging prod; do kc -n "$(ns_of "$e")" get deploy/payments >/dev/null 2>&1 || need_app=1; done
if [[ "$need_app" == 1 ]]; then
  SRC="$(mktemp -d)"
  gh repo clone "$REPO" "$SRC" -- --depth 1 -q || die "cannot clone $REPO"
  docker build --platform linux/amd64 --build-arg "GIT_SHA=$SHA" -t "$SEED" "$SRC" || die "app image build failed"
  docker push "$SEED" || die "app image push failed"
  rm -rf "$SRC"
  ok "pushed $SEED"
fi
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  log "SKIP_BUILD=1, reusing $MCP_IMAGE"
else
  docker build --platform linux/amd64 -t "$MCP_IMAGE" "$HERE/mcp" || die "MCP image build failed"
  docker push "$MCP_IMAGE" || die "MCP image push failed"
  if [[ -z "${TUB_AGENT_IMAGE:-}" ]]; then
    docker build --platform linux/amd64 -t "$AGENT_IMAGE" "$HERE/../trustusbank/agent-runtime" || die "agent image build failed"
    docker push "$AGENT_IMAGE" || die "agent image push failed"
  fi
  ok "pushed $MCP_IMAGE and $AGENT_IMAGE"
fi

# ── 2. the banking app, staging and prod ────────────────────────────────────
step "the payments app in $NS_staging and $NS_prod"
for e in staging prod; do
  ns="$(ns_of "$e")"
  kc create ns "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc label ns "$ns" company=trustusbank --overwrite >/dev/null
  pull_secret "$ns"
  # The image belongs to the approve/deny flow once the Deployment exists.
  img="$(kc -n "$ns" get deploy/payments -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  img="${img:-$SEED}"
  kc -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  labels: { app: payments, company: trustusbank }
spec:
  replicas: 1
  selector: { matchLabels: { app: payments } }
  template:
    metadata: { labels: { app: payments, company: trustusbank } }
    spec:
      imagePullSecrets: [{ name: ar-pull }]
      containers:
        - name: payments
          image: ${img}
          env: [{ name: APP_ENV, value: $(eval "printf %s \"\$ENV_$e\"") }]
          ports: [{ containerPort: 8080, name: http }]
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 5 }
          # Autopilot requires requests on every container.
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  labels: { company: trustusbank }
spec:
  selector: { app: payments }
  ports: [{ name: http, port: 80, targetPort: 8080 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments
  labels: { company: trustusbank }
spec:
  parentRefs: [{ name: ${GW}, namespace: ${AGW_NS} }]
  hostnames: ["$(host_of "$e")"]
  rules:
    - backendRefs: [{ name: payments, port: 80 }]
YAML
done
for e in staging prod; do
  kc -n "$(ns_of "$e")" rollout status deploy/payments --timeout=240s || die "payments did not start in $(ns_of "$e")"
done
ok "app up at http://$HOST_staging and http://$HOST_prod"

# ── 3. GitHub MCP servers behind agentgateway ───────────────────────────────
step "GitHub MCP servers for the PM and engineer agents in ns $MCP_NS"
kc create ns "$MCP_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
pull_secret "$MCP_NS"
# Read the one variable, not the whole file: secrets.env holds every lab licence key.
TOK="${TRUSTUSBANK_GITHUB_TOKEN:-$(sed -nE 's/^export GITHUB_PORTLAB_TOKEN=["'\'']?([^"'\'' ]*)["'\'']?.*$/\1/p' "$HERE/../../secrets.env" | head -1)}"
[[ -n "$TOK" ]] || die "no GitHub token: set TRUSTUSBANK_GITHUB_TOKEN or GITHUB_PORTLAB_TOKEN in secrets.env"
kc -n "$MCP_NS" create secret generic tub-sdlc-github --from-file=GITHUB_TOKEN=<(printf %s "$TOK") \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.github.com/repos/$REPO")"
unset TOK
[[ "$code" == 200 ]] || log "WARNING: the GitHub token gets HTTP $code for $REPO: the agents' GitHub tools will fail until it can see the repo"
for r in "${ROLES[@]}"; do
  kc -n "$MCP_NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sdlc-${r}
  labels: { app: sdlc-${r}, company: trustusbank }
spec:
  replicas: 1
  selector: { matchLabels: { app: sdlc-${r} } }
  template:
    metadata: { labels: { app: sdlc-${r}, company: trustusbank } }
    spec:
      imagePullSecrets: [{ name: ar-pull }]
      containers:
        - name: server
          image: ${MCP_IMAGE}
          imagePullPolicy: Always
          env:
            - { name: ROLE, value: ${r} }
            - { name: REPO, value: ${REPO} }
            - { name: STAGING_URL, value: "http://$HOST_staging" }
            - { name: PROD_URL, value: "http://$HOST_prod" }
            - name: GITHUB_TOKEN
              valueFrom: { secretKeyRef: { name: tub-sdlc-github, key: GITHUB_TOKEN } }
          ports: [{ containerPort: 3000, name: http }]
          readinessProbe: { tcpSocket: { port: 3000 }, periodSeconds: 5 }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: sdlc-${r}
  labels: { company: trustusbank, istio.io/use-waypoint: mcp-waypoint, mcp-lockdown/service: sdlc-${r} }
spec:
  selector: { app: sdlc-${r} }
  ports: [{ name: http, port: 3000, targetPort: 3000, appProtocol: kgateway.dev/mcp }]
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: sdlc-${r}-mcp
spec:
  mcp:
    targets:
      - name: sdlc-${r}
        selector:
          services:
            matchLabels: { mcp-lockdown/service: sdlc-${r} }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: sdlc-${r}-mesh
  labels: { company: trustusbank }
spec:
  parentRefs: [{ group: "", kind: Service, name: sdlc-${r} }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: sdlc-${r}-mcp
YAML
  # A new Secret value needs a restart to reach the pod's env.
  kc -n "$MCP_NS" rollout restart "deploy/sdlc-$r" >/dev/null 2>&1 || true
done
for r in "${ROLES[@]}"; do
  kc -n "$MCP_NS" rollout status "deploy/sdlc-$r" --timeout=180s || die "sdlc-$r did not start"
done

step "list each server's tools through the gateway, and reach the app, from inside the cluster"
kc -n "$MCP_NS" exec -i deploy/mcp-catalog -- python3 - "$BASE_DOMAIN" "${ROLES[@]}" <<'PY' \
  || die "the gateway does not serve the SDLC tools or the app"
import json, sys, urllib.request
from pathlib import Path
base, roles = sys.argv[1], sys.argv[2:]
H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
def post(url, body, sid=None):
    h = dict(H, **({"mcp-session-id": sid} if sid else {}))
    h["Authorization"] = "Bearer " + Path("/var/run/secrets/mcp/token").read_text().strip()
    r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), h), timeout=20)
    raw = r.read().decode()
    data = next((l[5:] for l in raw.splitlines() if l.startswith("data:")), raw)
    return r.headers.get("mcp-session-id"), (json.loads(data) if data.strip() else {})
for role in roles:
    url = "http://sdlc-%s.mcp.svc.cluster.local:3000/mcp" % role
    sid, _ = post(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "deploy", "version": "1"}}})
    post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, r = post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
    print("  sdlc-%-4s %s" % (role, ", ".join(t["name"] for t in r["result"]["tools"])))
for host in ("staging.payments." + base, "payments." + base):
    gw = "agentgateway-proxy.agentgateway-system.svc.cluster.local"
    req = urllib.request.Request("http://%s/api/config" % gw, headers={"Host": host})
    c = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print("  %-38s %s @ %s" % (host, c["env"], c["sha"]))
PY

# ── 4. AgentRegistry: the PM and engineer agents onto kagent ────────────────
step "catalogue the tools and agents in AgentRegistry, and push them onto kagent"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render mcp > "$TMP/mcp.yaml"; render agent > "$TMP/agent.yaml"; render kagent > "$TMP/kagent.yaml"
arctl apply -f "$TMP/mcp.yaml"   || die "could not catalogue the MCP servers"
arctl apply -f "$TMP/agent.yaml" || die "could not catalogue the agents"
# Earlier runs used an AR Deployment (a generated name) or the tub-sdlc-* names.
for a in "${AGENT_NAMES[@]}"; do
  arctl delete deployment "$a-kagent" >/dev/null 2>&1 || true
done
remove_agents "${OLD_NAMES[@]}"
kc apply -f "$TMP/kagent.yaml" >/dev/null || die "could not apply the kagent Agents"
for a in "${AGENT_NAMES[@]}"; do
  for _ in $(seq 1 60); do kc -n "$AR_NS" get "deploy/$a" >/dev/null 2>&1 && break; sleep 5; done
  kc -n "$AR_NS" rollout restart "deploy/$a" >/dev/null 2>&1 || true   # pick up a re-pushed :$TAG
  kc -n "$AR_NS" rollout status "deploy/$a" --timeout=300s || die "$a did not become ready"
done

step "what kagent runs"
python3 "$GCD_LAB/scripts/mcp_security.py" agents || die "agent identity reconciliation failed"
python3 "$GCD_LAB/scripts/mcp_security.py" servers || die "MCP enforcement reconciliation failed"
python3 "$GCD_LAB/scripts/mcp_security.py" discovery || die "MCP discovery identity reconciliation failed"
python3 "$GCD_LAB/scripts/mcp_policies.py" --apply || die "MCP tool grants failed"
kc -n "$AR_NS" get agents.kagent.dev | grep -E 'NAME|trustusbank-(pm|dev)-agent' || true
ok "TrustUsBank SDLC deployed: http://$HOST_staging · http://$HOST_prod · agents ${AGENT_NAMES[*]}"
