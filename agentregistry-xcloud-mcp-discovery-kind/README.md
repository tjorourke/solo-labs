# Calling MCP servers outside your cluster through agentregistry and agentgateway

Tested live on 9-10 Nov 2026. Solo Enterprise for agentregistry 2026.10.0, Solo Enterprise for agentgateway v2026.10.2 and Solo Enterprise for kagent 0.5.16 only. Standalone kind cluster `xcloud-mcp`. No OSS edition: the Virtual runtime that writes the gateway config is an Enterprise agentregistry feature.

## The story

A platform team has MCP servers it does not run itself, spread over two clouds. cloud-a has a health records service and a payments service. cloud-b has a telco network service and a compute inventory. Each has one tool developers should never call. The lab shows four things, in this order:

1. **Register your own MCP servers, or third-party ones, in agentregistry.** A server is catalogued by its URL. It does not have to run in your cluster or belong to your team. Here all four run as plain processes outside the cluster.
2. **agentregistry makes them available through agentgateway.** Deploying a registered server through the Virtual runtime writes the agentgateway backend and a `/registry/<name>` route. The platform team also puts all of them behind one path, `/mcp`, with a Keycloak sign-in in front.
3. **A user browses the registry from Codex, Claude Code or another agent harness.** The registry has its own read-only MCP server. From Codex, `list_servers` returns every registered server, and each server's tool list comes back through the gateway. The same read-only server also lists every other catalogue kind: agents, skills, prompts, runtimes, models and plugins.
4. **A developer calls the servers and tools their access allows.** dev-user signs in once per server and gets the tools a developer may use. Tools a developer isn't allowed to use don't appear.

Codex, Claude Code or another agent harness with OAuth sign-in connects to the same URLs. The steps below use Codex.

After that, two extra sections go further. "Browse the whole catalogue from Codex" asks that same registry MCP server for every agent, skill, prompt, runtime, model and plugin, not only MCP servers. Step 9 adds an ops agent in Solo Enterprise for kagent: it calls the same servers for a user, with a delegated token from the agentgateway token exchange service (STS), and gets the same tools that user would.

What each step shows:

| Step | What you do | What you see |
|---|---|---|
| 1 | Start four MCP servers outside the cluster | Four plain processes on the laptop, on ports 8001 to 8004 |
| 2 | Catalogue them in agentregistry by URL | `arctl get mcp` lists all four |
| 3 | Deploy them through the Virtual runtime | The registry writes the agentgateway backends and a `/registry/<name>` child route. `status.runtime.endpoint` shows the URL |
| 4 | Put Keycloak sign-in on the gateway | No token gives 401. The protected-resource metadata points MCP clients at Keycloak |
| 5 | Hide the sensitive tool on each server from developers | `get_patient_record`, `issue_refund`, `reset_cell_site` and `restart_vm` drop out of `tools/list` for dev-user and return 400 if called by name |
| 6 | Discover from Codex | Codex asks the read-only registry MCP which servers exist and where |
| 7 | Sign in from Codex and call tools | `codex mcp login lab-all` opens Keycloak, then Codex calls all four servers through one path, `/mcp` |
| 8 | Ask the kagent `cloud-ops` agent as dev-user | The agent calls the servers on `/agent/*` with a delegated STS token, and dev-user's agent never gets `restart_vm` |

## How the pieces fit

```
 Laptop                                 kind cluster xcloud-mcp                      Outside the cluster
 ------                                 -----------------------                      -------------------
 Codex ── lab-registry ── :31313 ──▶ agentregistry (registry MCP, read-only)
   │                                        │ writes backends + child routes
   │                                        ▼
   └──── lab-<server> ─── :8080 ───▶ agentgateway  /registry/health  ─────────▶  health-records    :8001  (cloud-a)
                                       JWT policy  /registry/finance ─────────▶  finance-payments  :8002  (cloud-a)
                                                   /registry/telco   ─────────▶  telco-network     :8003  (cloud-b)
                                                   /registry/compute ─────────▶  compute-inventory :8004  (cloud-b)
 Browser ── sign-in ───── :8180 ───▶ Keycloak (realm agentregistry)

 kagent API ── :18083 ──▶ cloud-ops agent ── user token ──▶ agentgateway STS :7777
                                │  ◀── delegated token (sub=user, Groups, act=cloud-ops)
                                └── delegated token ──▶ agentgateway /agent/health|finance|telco|compute ──▶ same four servers
 Solo UI ──── :19480
```

Codex discovers through the registry MCP (`list_deployments` returns the gateway endpoint), then connects to the gateway URL. On the first call the gateway answers 401 with a pointer to its protected-resource metadata. That metadata names Keycloak as the authorisation server, so Codex sends the browser straight to Keycloak and comes back with a token for audience `mcp-gateway`.

The policy leaves out `mcp.provider`. With `provider: Keycloak` the gateway rewrites the authorisation server issuer to its own URL, Keycloak still returns its own `iss`, and Codex rejects the mismatch. That is agentgateway issues #3668 and #3635. The fix, PR #3637, was not merged on 22 Oct 2026. Without `provider` the issuer stays Keycloak's and there is nothing to mismatch. The price is that Keycloak needs a pre-registered client (`codex-mcp`) because the gateway no longer proxies dynamic client registration.

Keycloak has one URL everywhere, because tokens carry `iss` and both the gateway and the registry check it. The laptop reaches Keycloak through a port-forward on 8180 and pods reach it through its Service, so both use `http://keycloak.127.0.0.1.nip.io:8180`. On the laptop nip.io resolves that name to 127.0.0.1. In the cluster a CoreDNS rewrite sends it to the Keycloak Service. Keycloak's `KC_HOSTNAME` pins the issuer to that URL.

## Before you start

Docker (for kind), kind, kubectl, Helm 3.12 or later, curl, jq, `uv`, OpenAI Codex CLI 0.167.0 or later, and `arctl` 2026.10.0:

```bash
curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh | ARCTL_VERSION=v2026.10.0 sh
export PATH=$HOME/.arctl/bin:$PATH
```

Licences come from your local secrets file, never the repo. Point `SECRETS_FILE` at it. If `AGENTREGISTRY_LICENSE_KEY` is not set, the scripts fall back to `SOLO_LICENSE_KEY`:

```bash
set -euo pipefail
set +x
export SECRETS_FILE=${SECRETS_FILE:-$HOME/.solo/secrets.env}
source "$SECRETS_FILE"
export AGENTREGISTRY_LICENSE_KEY=${AGENTREGISTRY_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}
: "${AGENTGATEWAY_LICENSE_KEY:?Set AGENTGATEWAY_LICENSE_KEY in the secrets file}"
: "${AGENTREGISTRY_LICENSE_KEY:?Set AGENTREGISTRY_LICENSE_KEY or SOLO_LICENSE_KEY in the secrets file}"
kind get clusters
```

If `xcloud-mcp` already exists, stop. Don't replace it.

```bash
kind create cluster --config kind/cluster.yaml
export CTX=kind-xcloud-mcp
```

## 1. Start four MCP servers outside the cluster

`mcp-servers/server.py` is one small FastMCP server with four personalities, picked with `SERVICE`. The data is made up and fixed so the demo does the same thing every time.

| Server | Cloud | Port | Route | Tools | Hidden from developers |
|---|---|---|---|---|---|
| `health-records` | cloud-a | 8001 | `/registry/health` | `search_patients`, `get_appointments` | `get_patient_record` |
| `finance-payments` | cloud-a | 8002 | `/registry/finance` | `get_account_balance`, `list_transactions` | `issue_refund` |
| `telco-network` | cloud-b | 8003 | `/registry/telco` | `get_cell_site_status`, `list_outages` | `reset_cell_site` |
| `compute-inventory` | cloud-b | 8004 | `/registry/compute` | `list_vms`, `get_vm`, `get_cost_by_vm` | `restart_vm` |

All four run as plain processes on the laptop, not in the cluster and not in Docker:

```bash
mkdir -p .state
SERVICE=health-records    PORT=8001 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py >.state/mcp-health-records.log 2>&1 &
SERVICE=finance-payments  PORT=8002 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py >.state/mcp-finance-payments.log 2>&1 &
SERVICE=telco-network     PORT=8003 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py >.state/mcp-telco-network.log 2>&1 &
SERVICE=compute-inventory PORT=8004 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py >.state/mcp-compute-inventory.log 2>&1 &
```

`./scripts/quick.sh servers-up` does the same and keeps the PIDs in `.state/`. `servers-status` and `servers-down` check and stop them. `servers-down` reads back that the PIDs have exited and the ports are free.

Pods reach the laptop through `host.docker.internal`, so the registry entries use `http://host.docker.internal:8001/mcp` to `:8004/mcp`. Checked on 9 Nov 2026 on OrbStack 29.8.2: a pod in the kind cluster got 200 from a server bound to 127.0.0.1. If your Docker runtime only forwards to 0.0.0.0, start the servers with `BIND_HOST=0.0.0.0`.

## 2. Keycloak

Point the issuer host at the Keycloak Service from inside the cluster. Add the line in `yaml/coredns-rewrite.txt` to the CoreDNS Corefile, just above `kubernetes cluster.local`:

```bash
kubectl --context "$CTX" -n kube-system edit configmap coredns
#   rewrite name exact keycloak.127.0.0.1.nip.io keycloak.keycloak.svc.cluster.local answer auto
kubectl --context "$CTX" -n kube-system rollout restart deployment/coredns
```

The realm is the Solo "General setup" realm plus four lab additions: a `mcp-gateway` client used only as a token audience, a public `codex-mcp` client with redirect `http://127.0.0.1:5555/*`, a `developers` group and a `dev-user`. See [yaml/keycloak-realm.yaml](yaml/keycloak-realm.yaml) and [yaml/keycloak.yaml](yaml/keycloak.yaml).

```bash
kubectl --context "$CTX" apply -f yaml/keycloak.yaml
kubectl --context "$CTX" apply -f yaml/keycloak-realm.yaml
kubectl --context "$CTX" -n keycloak rollout status deploy/keycloak --timeout=300s
kubectl --context "$CTX" -n keycloak port-forward svc/keycloak 8180:8180 --address=127.0.0.1 &
curl -s http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry/.well-known/openid-configuration | jq -r .issuer
```

The last line should print `http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry`. Then read the `ar-backend` secret the registry needs (same calls as the Solo Keycloak guide):

```bash
KC=http://127.0.0.1:8180
KEYCLOAK_TOKEN=$(curl -s -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
AR_BACKEND_ID=$(curl -s -H "Authorization: Bearer $KEYCLOAK_TOKEN" \
  "$KC/admin/realms/agentregistry/clients?clientId=ar-backend" | jq -r '.[0].id')
export AR_BACKEND_SECRET=$(curl -s -H "Authorization: Bearer $KEYCLOAK_TOKEN" \
  "$KC/admin/realms/agentregistry/clients/$AR_BACKEND_ID/client-secret" | jq -r .value)
```

## 3. Install Enterprise agentgateway and agentregistry

```bash
kubectl --context "$CTX" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
export R=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway-crds "$R/enterprise-agentgateway-crds" \
  --version v2026.10.2 -n agentgateway-system --create-namespace --wait
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | \
  kubectl --context "$CTX" -n agentgateway-system create secret generic enterprise-agentgateway-license \
  --from-file=enterprise-agentgateway-license-key=/dev/stdin --dry-run=client -o yaml | \
  kubectl --context "$CTX" apply -f -
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$R/enterprise-agentgateway" \
  --version v2026.10.2 -n agentgateway-system -f yaml/values.yaml --wait --timeout 6m

helm --kube-context "$CTX" upgrade --install agentregistry \
  oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise \
  --version 2026.10.0 --namespace agentregistry-system --create-namespace \
  --set licensing.createSecret=true \
  --set-file licensing.licenseKey=<(printf '%s' "$AGENTREGISTRY_LICENSE_KEY") \
  --set oidc.issuer=http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry \
  --set oidc.clientId=ar-backend \
  --set-file oidc.clientSecret=<(printf '%s' "$AR_BACKEND_SECRET") \
  --set oidc.publicClientId=ar-ui \
  --set oidc.roleClaim=Groups \
  --set-string 'rbac.superAdminPrincipals[0].all[0].attribute=Groups' \
  --set-string 'rbac.superAdminPrincipals[0].all[0].values[0]=admins' \
  --wait --timeout 8m
kubectl --context "$CTX" -n agentregistry-system get pods
```

The Solo install guide passes the licence with `--set licensing.licenseKey=...`. `--set-file` with a process substitution keeps it out of the process list. If your Helm rejects that, use the guide's form. Without a key that covers agentregistry, the server logs `agentregistry enterprise license missing or invalid` and still serves its API, so the lab runs either way.

## 4. Gateway and parent route (the platform team does this once)

[yaml/gateway.yaml](yaml/gateway.yaml) and [yaml/delegate-route.yaml](yaml/delegate-route.yaml) are straight from the Solo Virtual runtime guide. Both carry `agentregistry.solo.io/runtime: mcp-gateway`. The parent route hands everything under `/registry` to child routes in `agentregistry-system`, which the registry writes.

```bash
kubectl --context "$CTX" apply -f yaml/gateway.yaml -f yaml/delegate-route.yaml
kubectl --context "$CTX" -n agentgateway-system wait --for=condition=Programmed gateway/agentgateway-proxy --timeout=180s
kubectl --context "$CTX" -n agentgateway-system rollout status deployment/agentgateway-proxy --timeout=360s
```

Open the laptop side. Leave these running:

```bash
kubectl --context "$CTX" -n agentgateway-system port-forward deployment/agentgateway-proxy 8080:80 --address=127.0.0.1 &
kubectl --context "$CTX" -n agentregistry-system port-forward svc/agentregistry-enterprise-server 12121:12121 31313:31313 --address=127.0.0.1 &
```

## 5. Register and deploy through agentregistry

Sign `arctl` in as the platform team, then create the runtime, the four catalogue entries and the four Deployments:

```bash
export OIDC_ISSUER=http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry
arctl user login --oidc-flow=password-credentials --oidc-client-id=ar-cli-password \
  --oidc-username=admin-user --oidc-password=password
arctl apply -f - < registry/runtime.yaml
arctl apply -f - < registry/mcpservers.yaml
arctl apply -f - < registry/deployments.yaml
arctl apply -f - < registry/rbac.yaml
```

```yaml
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: compute-inventory
spec:
  title: "Compute inventory (cloud-b)"
  description: "VMs, their state and size, last month's cost per VM, and VM restarts. Hosted in cloud-b, outside the cluster."
  remote:
    type: streamable-http
    url: http://host.docker.internal:8004/mcp
---
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: compute
spec:
  targetRef:
    kind: MCPServer
    name: compute-inventory
    tag: latest
  runtimeRef:
    kind: Runtime
    name: mcp-gateway
  runtimeConfig:
    route:
      pathSuffix: /compute
    backend:
      mcp:
        authorization:
          action: Allow
          policy:
            matchExpressions:
              - '!jwt.Groups.exists(g, g == "developers")'
              - 'mcp.tool.name != "restart_vm"'
```

`action: Allow` lets a call through when any expression is true. For the `developers` group the second expression decides, so a developer gets everything except the sensitive tool. The other three servers use the same shape with their own hidden tool. The compute pair is shown above. The full files are in [registry/](registry/). `rbac.yaml` gives the `developers` group read access to the catalogue so dev-user can use the registry MCP.

Check what the registry did:

```bash
arctl get mcp
arctl get deployments -o yaml | grep -A8 '^status:'
kubectl --context "$CTX" get enterpriseagentgatewaybackends,httproutes -n agentregistry-system
```

Each Deployment should be `Ready` with reason `DeployedViaAgentgateway`. You should see one `gw-dep-*` backend per server, plus a child route. `status.runtime.endpoint` shows the gateway's address inside the kind network. From the laptop the same path is on `http://localhost:8080`.

## 6. Keycloak sign-in on the gateway

[yaml/jwt-policy.yaml](yaml/jwt-policy.yaml) targets the parent route, so it covers every server the registry exposes now or later. It requires a Keycloak token with audience `mcp-gateway`, and its `mcp` block switches on the OAuth discovery documents MCP clients look for.

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: registry-mcp-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agentregistry-delegate
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: registry-oauth-metadata
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry"
          audiences:
            - mcp-gateway
          jwks:
            remote:
              jwksPath: /realms/agentregistry/protocol/openid-connect/certs
              backendRef:
                name: keycloak
                kind: Service
                namespace: keycloak
                port: 8180
      mcp:
        resourceMetadata:
          scopesSupported:
            - openid
            - profile
          bearerMethodsSupported:
            - header
```

The registry's child routes only match `/registry/<name>`, but a client looks for `/.well-known/oauth-protected-resource/registry/<name>`. [yaml/oauth-metadata.yaml](yaml/oauth-metadata.yaml) adds one route with a rule and a small MCP backend for each of the four paths so the gateway can answer them. This is the one piece of gateway config the platform team writes per server they want Codex to sign in to.

```bash
kubectl --context "$CTX" apply -f yaml/oauth-metadata.yaml
kubectl --context "$CTX" apply --dry-run=server -f yaml/jwt-policy.yaml
kubectl --context "$CTX" apply -f yaml/jwt-policy.yaml
kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaypolicies
```

Check it from the laptop:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{}' http://localhost:8080/registry/compute
curl -s http://localhost:8080/.well-known/oauth-protected-resource/registry/compute | jq
```

The first prints `401`. The second should show `resource` as `http://localhost:8080/registry/compute` and `authorization_servers` as the Keycloak issuer. If `resource` is anything else, fix it before going near Codex.

## 7. Prove the tool filter with curl

```bash
eval "$(./scripts/mint-token.sh dev-user)"
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $LAB_MCP_TOKEN")
SID=$(curl -s -D - -o /dev/null "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0.1"}}}' \
  http://localhost:8080/registry/compute | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' http://localhost:8080/registry/compute
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' http://localhost:8080/registry/compute | grep -o '"name":"[a-z_]*"'
curl -s -o /dev/null -w '%{http_code}\n' "${H[@]}" -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restart_vm","arguments":{"name":"checkout-api-02"}}}' \
  http://localhost:8080/registry/compute
```

dev-user sees `list_vms`, `get_vm` and `get_cost_by_vm` only. Calling `restart_vm` by name gives `400`. The gateway answers with JSON-RPC error -32602 "unknown resource" and no 403, so a developer can't tell the tool exists.

## 8. One MCP path for every server

agentregistry gives each deployed server its own path on the gateway, `/registry/<name>`. That would mean one client entry and one sign-in per server. Instead, the platform team puts all of them behind one path, `/mcp`, once. agentgateway combines the servers into a single MCP server and puts the server name in front of each tool name, so `list_vms` from the compute server becomes `compute_list_vms`. The same Keycloak sign-in protects the path, and one rule hides the four sensitive tools from developers. `quick.sh up` applies it; by hand it is:

```
kubectl apply -f yaml/one-path.yaml
```

The registry doesn't create this combined path itself, so it is gateway configuration the platform team keeps. Here is what dev-user gets, with a token from Keycloak and plain curl:

```
TOKEN=$(curl -s -d client_id=ar-cli-password -d grant_type=password \
  -d username=dev-user -d password=password -d scope=openid \
  http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry/protocol/openid-connect/token | jq -r .access_token)
# password is the lab's demo password; nothing is printed

URL=http://localhost:8080/mcp
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $TOKEN")
SID=$(curl -s -D - -o /dev/null "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0.1"}}}' \
  $URL | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' $URL
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' $URL \
  | sed -n 's/^data: //p' | jq -r '.result.tools[].name'
```

```
health_search_patients
health_get_appointments
finance_get_account_balance
finance_list_transactions
telco_get_cell_site_status
telco_list_outages
compute_list_vms
compute_get_vm
compute_get_cost_by_vm
```

The tools a developer isn't allowed to use don't appear. Calling one tool on two different servers through the same path:

```
curl -s "${H[@]}" -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"compute_list_vms","arguments":{"region":"eu-london-1"}}}' $URL \
  | sed -n 's/^data: //p' | jq -c '.result.structuredContent.result[] | {name, state}'
curl -s "${H[@]}" -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"telco_list_outages","arguments":{"status":"open"}}}' $URL \
  | sed -n 's/^data: //p' | jq -c '.result.structuredContent.result[]'
```

```
{"name":"checkout-api-01","state":"running"}
{"name":"checkout-api-02","state":"stopped"}
{"id":"OUT-5521","site":"MAN-CS-0033","started":"2026-11-09T06:12:00Z","impact":"approx. 4,100 subscribers","status":"open"}
```

### Try it in Codex as dev-user

Back up your Codex config and add one entry. `mcp_oauth_callback_port` is a top-level key, so it goes above the first `[table]` in the file.

```
cp ~/.codex/config.toml ~/.codex/config.toml.bak
```

```
mcp_oauth_callback_port = 5555

[mcp_servers.lab-all]
url = "http://localhost:8080/mcp"
scopes = ["openid", "profile"]

[mcp_servers.lab-all.oauth]
client_id = "codex-mcp"
callback_url = "http://127.0.0.1:5555/callback"
```

Sign in from a normal terminal, not inside a Codex chat, because the chat sandbox can't reach localhost. Keycloak opens; sign in as dev-user.

```
codex mcp list
codex mcp login lab-all
```

```
Name          Url                                     Bearer Token Env Var  Status   Auth
lab-all       http://localhost:8080/mcp               -                     enabled  Not logged in
```

Run on 9 Nov 2026 with Codex 0.167.0 and a dev-user token: Codex had the nine developer tools from all four servers, `compute_list_vms` returned checkout-api-01 (running) and checkout-api-02 (stopped), and `finance_list_transactions` on ACC-20-45-77-55510321 returned TXN-88240 and TXN-88241. To undo, `cp ~/.codex/config.toml.bak ~/.codex/config.toml`.

For a non-interactive `codex exec` run, approve the tools you call, for example `-c 'mcp_servers.lab-all.tools.compute_list_vms.approval_mode="approve"'`. Without it Codex refuses with "MCP tool call requires approval, but approval policy is never". `./scripts/codex-config.sh apply` writes the same `lab-all` entry (and a `lab-registry` entry for the registry's own MCP server) as a shortcut.


## Register your own MCP server

This is how a team adds a new service. The example is a logistics shipment-tracking server, `logistics-shipments`, that a delivery team runs on port 8005. Every command and output below is from a live run against this lab on 9 Nov 2026.

1. **Start the server, or use the URL of one that already runs.** The registry only needs a URL that pods can reach. A server on the laptop is `http://host.docker.internal:<port>/mcp` from inside kind.

   ```
   SERVICE=logistics-shipments PORT=8005 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py &
   ```

2. **Register it and deploy it to the Virtual runtime in one command.** Registering needs `manage` access in agentregistry, which in this lab the platform team has, so sign `arctl` in with that account first (`arctl user login`). The file holds the catalogue entry and a Deployment on the `mcp-gateway` Virtual runtime. For your own server change the names, `url`, `pathSuffix` and the hidden tool.

   ```
   arctl apply -f - <<'YAML'
   apiVersion: ar.dev/v1alpha1
   kind: MCPServer
   metadata:
     name: logistics-shipments
   spec:
     title: "Logistics shipments"
     description: "Shipment tracking and delayed shipments for the UK depot network."
     remote:
       type: streamable-http
       url: http://host.docker.internal:8005/mcp
   ---
   apiVersion: ar.dev/v1alpha1
   kind: Deployment
   metadata:
     name: logistics
   spec:
     targetRef:
       kind: MCPServer
       name: logistics-shipments
       tag: latest
     runtimeRef:
       kind: Runtime
       name: mcp-gateway
     runtimeConfig:
       route:
         pathSuffix: /logistics
       backend:
         mcp:
           authorization:
             action: Allow
             policy:
               matchExpressions:
                 - '!jwt.Groups.exists(g, g == "developers")'
                 - 'mcp.tool.name != "cancel_shipment"'
   YAML
   ```

   ```
   ✓ MCPServer/logistics-shipments (latest) created
   ✓ Deployment/logistics created
   ```

   arctl 2026.10.0 has no `arctl deploy` command, so the Deployment record is what puts a server on agentgateway. Within seconds the registry wrote its own route, `/registry/logistics`:

   ```
   arctl get deployments
   ```

   ```
   NAME                TARGET                VERSION   TYPE   RUNTIME       STATUS
   default/compute     compute-inventory     latest    mcp    mcp-gateway   deployed
   default/finance     finance-payments      latest    mcp    mcp-gateway   deployed
   default/health      health-records        latest    mcp    mcp-gateway   deployed
   default/logistics   logistics-shipments   latest    mcp    mcp-gateway   deployed
   default/telco       telco-network         latest    mcp    mcp-gateway   deployed
   ```

3. **Add it to the one MCP path.** The registry doesn't do this part itself: the new server is not on `/mcp` until it is added there. In `yaml/one-path.yaml`, add a target under the compute one and extend the developer rule, then apply it:

   ```
         - name: logistics
           static: {host: host.docker.internal, port: 8005, path: /mcp, protocol: StreamableHTTP}
   ```

   ```
                 !(mcp.tool.target == "compute" && mcp.tool.name == "restart_vm") &&
                 !(mcp.tool.target == "logistics" && mcp.tool.name == "cancel_shipment")
   ```

   ```
   kubectl apply -f yaml/one-path.yaml
   ```

   Without the rule change, dev-user would see `logistics_cancel_shipment`.

4. **List every MCP server in the registry, as dev-user.** With the dev-user `TOKEN` from above, ask arctl or the registry API. The new server is there straight away.

   ```
   arctl get mcps --registry-token "$TOKEN"
   curl -s -H "Authorization: Bearer $TOKEN" http://localhost:12121/v0/mcpservers | jq -r '.items[] | "\(.metadata.name)\t\(.spec.remote.url)"'
   ```

   ```
   NAME                  TAG      DESCRIPTION
   compute-inventory     latest   VMs, their state and size, last month's cost per VM, and ...
   finance-payments      latest   Account balances, transactions and refunds for business a...
   health-records        latest   Patient search, appointments and full patient records for...
   logistics-shipments   latest   Shipment tracking and delayed shipments for the UK depot ...
   telco-network         latest   Cell-site status, outages and cell-site resets for the ra...

   compute-inventory     http://host.docker.internal:8004/mcp
   finance-payments      http://host.docker.internal:8002/mcp
   health-records        http://host.docker.internal:8001/mcp
   logistics-shipments   http://host.docker.internal:8005/mcp
   telco-network         http://host.docker.internal:8003/mcp
   ```

5. **Call it as dev-user through `/mcp`.** Open a new session as above and run `tools/list` again. The two logistics tools a developer may use are added, and `cancel_shipment` isn't there:

   ```
   ...
   compute_get_cost_by_vm
   logistics_track_shipment
   logistics_list_delayed_shipments
   ```

   ```
   curl -s "${H[@]}" -H "mcp-session-id: $SID" \
     -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"logistics_list_delayed_shipments","arguments":{"depot":"Daventry DC"}}}' $URL \
     | sed -n 's/^data: //p' | jq '.result.structuredContent.result'
   ```

   ```
   [
     {"shipment_id": "SHP-20944", "origin": "Daventry DC", "destination": "Bristol", "eta": "2026-11-11", "delay_reason": "vehicle fault"},
     {"shipment_id": "SHP-20963", "origin": "Daventry DC", "destination": "Glasgow", "eta": "2026-11-12", "delay_reason": "missed trunk departure"}
   ]
   ```

   Codex needs no new entry: `lab-all` picks up the new tools the next time it starts. Asked "Use lab-all to track shipment SHP-20931", it answered: `SHP-20931 is in transit to Leeds; ETA 10 November 2026; last scanned at Daventry DC on 9 November at 18:42.`

To remove it: take the logistics lines back out of `yaml/one-path.yaml` and apply it, run `arctl delete deployment logistics` and `arctl delete mcp logistics-shipments`, and stop the process on port 8005.


## Browse the whole catalogue from Codex

The read-only registry MCP on port 31313 that step 6 used to discover the four servers isn't limited to MCP servers. The same server, same bearer token, also has `list_agents`, `list_skills`, `list_prompts`, `list_runtimes`, `list_models` and `list_plugins`.

This lab's catalogue so far holds only the four servers and two runtimes, so those calls would come back empty. [registry/catalogue.yaml](registry/catalogue.yaml) adds one of each other kind: a `Model`, an `Agent` for the `cloud-ops` agent from step 9 below, a `Skill`, a `Prompt`, and a `Plugin` that reuses the one already published in [Claude Code plugins in AgentRegistry](https://www.masterthemesh.com/solo/agentregistry-plugins/).

```bash
arctl apply -f - < registry/catalogue.yaml
```

```
✓ Model/claude-opus-bedrock (latest) created
✓ Agent/cloud-ops (latest) created
✓ Skill/agentgateway-policy-review (latest) created
✓ Prompt/telco-outage-triage (latest) created
✓ Plugin/agentgateway-policy-review (latest) created
```

The Skill and the Plugin both point at the one already published in [Claude Code plugins in AgentRegistry](https://www.masterthemesh.com/solo/agentregistry-plugins/): the Skill at one real subfolder inside it, the Plugin at the whole repository. Their `description` fields above are hand-written, same as every other entry in this file; what's genuinely server-resolved is each one's `status`, not shown here: agentregistry pins the git commit, and for the Plugin, scans the bundle for its real skills, commands and hooks.

One more thing the platform team has to do. The `developers-read` RBAC policy from step 5 only granted `view` on MCP servers, Deployments and runtimes. Without a grant for each of the other five kinds, dev-user's `list_agents`, `list_skills`, `list_prompts`, `list_models` and `list_plugins` calls all come back `count: 0`, even once the entries exist. [registry/rbac.yaml](registry/rbac.yaml) adds the five grants:

```yaml
    - name: view-agents
      accessLevel: view
      resource: agents
    - name: view-skills
      accessLevel: view
      resource: skills
    - name: view-prompts
      accessLevel: view
      resource: prompts
    - name: view-models
      accessLevel: view
      resource: models
    - name: view-plugins
      accessLevel: view
      resource: plugins
```

```bash
arctl apply -f - < registry/rbac.yaml
```

Codex reaches this bridge the same way `codex-config.sh apply` already set up in step 8's Codex section: a `lab-registry` entry with a bearer token, no sign-in step.

```bash
codex mcp list
```

```
Name          Url                         Bearer Token Env Var  Status   Auth
lab-all       http://localhost:8080/mcp   -                     enabled  Not logged in
lab-registry  http://localhost:31313/mcp  LAB_AR_TOKEN          enabled  Bearer token
```

Mint a token and ask Codex to browse the whole catalogue, not look up anything by name. For a non-interactive `codex exec` run, approve the seven `list_*` tools on `lab-registry` up front, the same way step 8 approves `lab-all`'s tools; without it Codex refuses each one with "MCP tool call requires approval, but approval policy is never":

```bash
eval "$(./scripts/mint-token.sh dev-user)"
codex exec \
  -c 'mcp_servers.lab-registry.tools.list_servers.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_agents.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_skills.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_prompts.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_runtimes.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_models.approval_mode="approve"' \
  -c 'mcp_servers.lab-registry.tools.list_plugins.approval_mode="approve"' \
  "Using lab-registry, list every MCP server, agent, skill, prompt, runtime, model and \
plugin registered in AgentRegistry. For each kind, name every item and its one-line description."
```

Run live on 10 Nov 2026 with Codex 0.167.0, this called `list_servers`, `list_agents`, `list_skills`, `list_prompts`, `list_runtimes`, `list_models` and `list_plugins` on `lab-registry`, one each, and answered:

```
AgentRegistry currently has 11 registered items across the seven requested kinds. All listed entries are tagged `latest` except the two runtimes, which have no tag.

### MCP servers (4)
- compute-inventory — VMs, their state and size, last month's cost per VM, and VM restarts; hosted in cloud-b, outside the cluster.
- finance-payments — Account balances, transactions, and refunds for business accounts; hosted in cloud-a, outside the cluster.
- health-records — Patient search, appointments, and full patient records for the clinics; hosted in cloud-a, outside the cluster.
- telco-network — Cell-site status, outages, and cell-site resets for the radio network; hosted in cloud-b, outside the cluster.

### Agents (1)
- cloud-ops — Answers questions about VMs, costs, payments, cell sites, and patient records across cloud-a and cloud-b, using the lab's four MCP servers.

### Skills (1)
- agentgateway-policy-review — Reviews agentgateway or kgateway configuration YAML against a field checklist and bundled linter; read-only and never applies changes to a cluster.

### Prompts (1)
- telco-outage-triage — Starting prompt for a developer triaging an open telco outage.

### Runtimes (2)
Neither runtime has a description field registered; both are configured with type Virtual.
- mcp-gateway — Virtual runtime.
- virtual-default — Virtual runtime.

### Models (1)
- claude-opus-bedrock — Bedrock-hosted Claude Opus catalogue sample; the description says nothing in this lab calls it.

### Plugins (1)
- agentgateway-policy-review — Reviews agentgateway and kgateway configuration in files or against a live cluster; read-only, and ships skills, commands, an auditor agent, a hook, executables, and an MCP server.
```

Only a read-only record of each kind comes back this way. There's no tool here to call a cataloged MCP server's own tools, or run an agent. That's what the `/registry/*` and `/mcp` paths above are for. This bridge is the catalogue, not the traffic.

To remove it: `arctl delete model claude-opus-bedrock`, `arctl delete agent cloud-ops`, `arctl delete skill agentgateway-policy-review`, `arctl delete prompt telco-outage-triage`, `arctl delete plugin agentgateway-policy-review`, and take the five `view-*` grants back out of `registry/rbac.yaml`.


## 9. Extra: a kagent agent calling the same servers for the user
Codex calls the gateway with your own Keycloak token. An agent should not. Here the `cloud-ops` agent in Solo Enterprise for kagent swaps the user's token at the agentgateway token exchange service (STS) for a delegated token. That token carries the user (`sub`, `Groups`) and the agent (`act`, its service account). The agent reaches the same four servers on a separate `/agent/*` route that only trusts the STS. The same per-tool rule applies, keyed on the user's groups.

```bash
./scripts/quick.sh up-kagent            # STS on, Keycloak clients, kagent-enterprise and the Solo UI
kubectl --context "$CTX" apply --dry-run=server -f yaml/agent-route.yaml -f kagent/cloud-ops.yaml
kubectl --context "$CTX" apply -f yaml/agent-route.yaml -f kagent/cloud-ops.yaml
./scripts/quick.sh kagent-port-forward  # Solo UI on http://localhost:19480, kagent API on 18083
./scripts/quick.sh test-agent
```
Three things had to be right before the agent got a tool list:

- The user token must name the agent in `may_act`. Without it the STS refuses with `subject token does not contain may_act claim`. The lab adds a fixed `may_act` mapper for `system:serviceaccount:kagent:cloud-ops`.
- `oidc.skipOBO: true` in the kagent values. It is marked deprecated, but without it 0.5.16 answers `obo token handler not ready`.
- The agent runs on the Python runtime. On the Go runtime the STS exchange succeeded but the MCP calls reached the gateway with no bearer token (401).

Tested live on 9 Nov 2026:

- As `dev-user`, "Which VMs in eu-london-1 are stopped and what do they cost?" came back with `checkout-api-02` at £960.45 for 2026-10.
- As `dev-user`, "restart checkout-api-02" made no `restart_vm` call, because the gateway never lists that tool for developers. The agent did not say it lacked a restart tool. It replied that `checkout-api-02` is already stopped, so there is nothing to restart, and offered to help start it.

Solo Enterprise for kagent also logs `kagent enterprise license missing or invalid` without a kagent key, and still runs.


## Scripts

Optional shortcuts. The steps above are the lab.

- `./scripts/quick.sh up` builds everything above and leaves it running. Refuses an existing `xcloud-mcp` cluster.
- `./scripts/quick.sh test` checks the curl path end to end and prints PASS or FAIL per check.
- `./scripts/quick.sh up-kagent`, `test-agent`, `kagent-port-forward` and `down-kagent` build, check, reach and remove step 9 only. `test-agent` checks the STS, the `/agent/*` policy, a hand-made token exchange, 401s without an STS token, the developer tool list and the three agent questions.
- `./scripts/quick.sh servers-up`, `servers-status` and `servers-down` start, check and stop the four MCP server processes.
- `./scripts/quick.sh port-forward` and `stop-port-forward` start and stop the three laptop port-forwards.
- `./scripts/demo.sh` walks the live demo one command at a time.
- `./scripts/codex-config.sh show|apply|bearer|oauth|remove`.

Only after review:

```bash
./scripts/codex-config.sh remove
./scripts/quick.sh down-kagent      # optional: remove only step 9 and keep the rest
CONFIRM_TEARDOWN=xcloud-mcp ./scripts/quick.sh teardown
```

`down-kagent` removes the agent, the `/agent/*` route, kagent, the Solo UI, the two Keycloak clients and the `may_act` mapper, and turns the STS off again. Teardown deletes the cluster and stops the four MCP server processes, then checks the cluster is gone, the PIDs have exited and ports 8001 to 8004 are free. Nothing tears down on exit or on failure.

## What this lab doesn't cover

One agent only: no calls from one agent to another and no kagent AccessPolicies. Also out: token exchange to the upstream clouds. TLS is off everywhere because this is a laptop demo.
