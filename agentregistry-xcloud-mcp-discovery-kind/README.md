# Calling MCP servers outside your cluster through agentregistry and agentgateway

Tested live on 9 Nov 2026. Solo Enterprise for agentregistry 2026.10.0, Solo Enterprise for agentgateway v2026.10.2 and Solo Enterprise for kagent 0.5.16 only. Standalone kind cluster `xcloud-mcp`. No OSS edition: the Virtual runtime that writes the gateway config is an Enterprise agentregistry feature.

## The story

A platform team has MCP servers it does not run itself, spread over two clouds. cloud-a has a health records service and a payments service. cloud-b has a telco network service and a compute inventory. Each has one tool developers should never call. The lab shows four things, in this order:

1. **Register your own MCP servers, or other people's, in agentregistry.** A server is catalogued by its URL. It does not have to run in your cluster or belong to your team. Here all four run as plain processes outside the cluster.
2. **agentregistry makes them available through agentgateway.** Deploying a registered server through the Virtual runtime writes the agentgateway backend and a `/registry/<name>` route, so every call goes through one gateway with a Keycloak sign-in in front.
3. **A user can browse the registry from Codex.** The registry has its own read-only MCP server. From Codex, `list_servers` returns every registered server, and each server's tool list comes back through the gateway.
4. **A developer calls the servers and tools their access allows.** dev-user signs in once per server and gets the tools a developer may use. Tools a developer isn't allowed to use don't appear.

Codex is the example client and the one tested here. Claude Code or any other MCP client with OAuth sign-in connects to the same URLs the same way. That has not been tested.

After that, an extra section (step 9) adds an ops agent in Solo Enterprise for kagent. It calls the same servers for a user, with a delegated token from the agentgateway token exchange service (STS), and gets the same tools that user would.

What each step shows:

| Step | What you do | What you see |
|---|---|---|
| 1 | Start four MCP servers outside the cluster | Four plain processes on the laptop, on ports 8001 to 8004 |
| 2 | Catalogue them in agentregistry by URL | `arctl get mcp` lists all four |
| 3 | Deploy them through the Virtual runtime | The registry writes the agentgateway backends and a `/registry/<name>` child route. `status.runtime.endpoint` shows the URL |
| 4 | Put Keycloak sign-in on the gateway | No token gives 401. The protected-resource metadata points MCP clients at Keycloak |
| 5 | Hide the sensitive tool on each server from developers | `get_patient_record`, `issue_refund`, `reset_cell_site` and `restart_vm` drop out of `tools/list` for dev-user and return 400 if called by name |
| 6 | Discover from Codex | Codex asks the read-only registry MCP which servers exist and where |
| 7 | Sign in from Codex and call tools | `codex mcp login lab-compute` opens Keycloak, then Codex calls compute-inventory through the gateway |
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

## 8. Run it with Codex

Needs Codex 0.167.0 or later (`codex --version`) and the port-forwards up (`./scripts/quick.sh port-forward`). If any of them drop (for example after a pod restart), run `./scripts/quick.sh stop-port-forward && ./scripts/quick.sh port-forward`.

Show the change first. Nothing is written until you run `apply`, which makes a timestamped backup of `~/.codex/config.toml`. It touches nothing else.

```bash
./scripts/codex-config.sh show
./scripts/codex-config.sh apply
codex mcp list        # lab-registry: Bearer token, the four lab-<server> entries: OAuth
```

```toml
mcp_oauth_callback_port = 5555

[mcp_servers.lab-registry]
url = "http://localhost:31313/mcp"
bearer_token_env_var = "LAB_AR_TOKEN"

[mcp_servers.lab-compute]
url = "http://localhost:8080/registry/compute"
scopes = ["openid", "profile"]

[mcp_servers.lab-compute.oauth]
client_id = "codex-mcp"
callback_url = "http://127.0.0.1:5555/callback"
```

`mcp_oauth_callback_port` is a top-level key, so the script puts it above your first `[table]` and the server tables (lab-registry, lab-health, lab-finance, lab-telco, lab-compute) at the end, each inside marker comments. `remove` takes out only what is between the markers.

**Registry discovery (`lab-registry`).** The registry MCP on 31313 takes a bearer token for a registry user. A Keycloak dev-user token works, and so does an `arctl` session token. `mint-token.sh` prints export lines, so eval it rather than wrapping it in `$(...)`. Start Codex from the same shell, because Codex reads `LAB_AR_TOKEN` when it starts:

```bash
eval "$(./scripts/mint-token.sh dev-user)"   # sets LAB_AR_TOKEN and LAB_MCP_TOKEN; Keycloak tokens last 5 minutes
```

**Sign in to each server (browser).** Run this in a normal terminal, not inside a Codex chat. Codex runs chat commands in a sandbox that can't reach localhost, so the sign-in fails there:

```bash
codex mcp login lab-compute    # then lab-health, lab-finance and lab-telco
```

Keycloak's agentregistry realm opens. Sign in as `dev-user`, with the password from `yaml/keycloak-realm.yaml` (users, dev-user, credentials). Keycloak sends you back to `http://127.0.0.1:5555/callback`, the redirect registered for the `codex-mcp` client. `codex mcp list` then shows lab-compute as signed in.

Tested live on 9 Nov 2026 with Codex 0.167.0 and all four servers. I signed in with `codex mcp login` for `lab-health`, `lab-finance`, `lab-telco` and `lab-compute` in a normal terminal, as `dev-user` (the gateway log shows dev-user's `sub` on every call). `codex mcp list` then showed all four as OAuth and `lab-registry` as a bearer token. In Codex:

- `lab-registry`'s `list_servers` returned `compute-inventory`, `finance-payments`, `health-records` and `telco-network`.
- The tools Codex had were `search_patients` and `get_appointments` from health, `get_account_balance` and `list_transactions` from finance, `get_cell_site_status` and `list_outages` from telco, and `list_vms`, `get_vm` and `get_cost_by_vm` from compute. None of the four sensitive tools showed up.
- `list_vms` for eu-london-1 went through `/registry/compute` and picked out `checkout-api-02` as the only stopped VM.
- Asked to restart `checkout-api-02`, Codex said it had no VM restart tool.

For a non-interactive `codex exec` run, approve the tools you call, for example `-c 'mcp_servers.lab-compute.tools.list_vms.approval_mode="approve"'`. Without it Codex refuses with "MCP tool call requires approval, but approval policy is never".


`codex exec`, the non-interactive form used to script this, needs `--approve-for-me`. Without it the MCP tool calls are denied under its default `never` approval policy. The interactive `codex` that this lab uses doesn't have this problem.

Checked without signing in (9 Nov 2026):
- An unauthenticated call to `/registry/compute` returns `401`, with `resource_metadata` pointing to `/.well-known/oauth-protected-resource/registry/compute`.
- That document names the Keycloak realm issuer and scopes `openid profile`.
- Keycloak's metadata advertises `authorization_response_iss_parameter_supported: true` and S256 PKCE, so Codex keeps the configured callback.
- Keycloak accepts `http://127.0.0.1:5555/callback` for `codex-mcp` and rejects any other port.

**Try it:**

```bash
codex
```

- "Use lab-registry to list the MCP servers and deployments. Which endpoints do they have?" (`list_servers`, `list_deployments`: the four servers, at `/registry/health`, `/registry/finance`, `/registry/telco` and `/registry/compute`)
- "Use lab-compute to list the VMs. Which are stopped in eu-london-1?" (`list_vms` through the gateway)
- "Which telco outages are open, and how many subscribers do they affect?" (`list_outages` through lab-telco)
- "Show me the full record for patient PT-104233." (dev-user has no `get_patient_record`, so Codex can't)
- "Restart checkout-api-02." (dev-user has no such tool, so Codex can't call it)

Or call one with curl:

```bash
source scripts/lib.sh; eval "$(./scripts/mint-token.sh dev-user)"
s=$(mcp_init "$GW_LOCAL/registry/finance" "$LAB_MCP_TOKEN")
mcp_rpc "$GW_LOCAL/registry/finance" "$LAB_MCP_TOKEN" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_account_balance","arguments":{"account_id":"ACC-20-45-77-10293847"}}}'
```

**Bearer fallback.** If the browser sign-in fails on stage, switch the four server entries to a pasted token. The gateway runs the same check without the browser:

```bash
./scripts/codex-config.sh bearer             # the lab-<server> entries use bearer_token_env_var = "LAB_MCP_TOKEN"
eval "$(./scripts/mint-token.sh dev-user)"
codex
./scripts/codex-config.sh oauth              # back to Keycloak sign-in
```

Remove the lab entries afterwards with `./scripts/codex-config.sh remove`.

## Register your own MCP server

The four lab servers are only examples. The same five steps bring in any remote MCP server that speaks streamable HTTP, whether your team runs it or someone else does. The worked example adds a fifth server, `my-inventory`, on port 8005 at `/registry/mine`. Steps 1 to 3 and the dev-user checks in step 5 were run against this lab on 9 Nov 2026, with curl. The Codex entry and sign-in in step 4 were not run for a fifth server.

1. **Run the server, or point at one that already runs.** The registry only needs a URL that pods can reach. For the example, start another copy of the lab server on 8005:

   ```bash
   SERVICE=compute-inventory PORT=8005 uv run --python 3.12 --with fastmcp==4.1.6 mcp-servers/server.py &
   ```

   For your own server, skip this and use its URL. A server on the laptop is `http://host.docker.internal:<port>/mcp` from inside kind.

2. **Register it in agentregistry.** Change `name`, `title`, `description` and `url` for your own server:

   ```yaml
   apiVersion: ar.dev/v1alpha1
   kind: MCPServer
   metadata:
     name: my-inventory
   spec:
     title: "My inventory"
     description: "A second copy of the compute inventory, standing in for your own server."
     remote:
       type: streamable-http
       url: http://host.docker.internal:8005/mcp
   ```

   ```bash
   export OIDC_ISSUER=http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry
   arctl apply -f - <my-mcpserver.yaml      # with the platform team's arctl login from step 5
   ```

3. **Make it available through agentgateway.** A Deployment on the `mcp-gateway` Virtual runtime does this. Change `name`, `targetRef.name`, `pathSuffix` and the hidden tool name:

   ```yaml
   apiVersion: ar.dev/v1alpha1
   kind: Deployment
   metadata:
     name: mine
   spec:
     targetRef:
       kind: MCPServer
       name: my-inventory
       tag: latest
     runtimeRef:
       kind: Runtime
       name: mcp-gateway
     runtimeConfig:
       route:
         pathSuffix: /mine
       backend:
         mcp:
           authorization:
             action: Allow
             policy:
               matchExpressions:
                 - '!jwt.Groups.exists(g, g == "developers")'
                 - 'mcp.tool.name != "restart_vm"'
   ```

   ```bash
   arctl apply -f - <my-deployment.yaml
   arctl get deployments -o yaml | grep -A40 'name: mine' | grep -E 'reason|endpoint'
   kubectl --context "$CTX" -n agentregistry-system get httproute,enterpriseagentgatewaybackends | grep mine
   ```

   The registry writes an `EnterpriseAgentgatewayBackend` and a child `HTTPRoute` under the `agentregistry-delegate` parent route, so the `registry-mcp-auth` JWT policy covers `/registry/mine` with no change. The Deployment reports `DeployedViaAgentgateway` and an endpoint ending in `/registry/mine`. The sign-in metadata for the new path is the one manual piece. Add a `mine-prm` backend and a rule to `yaml/oauth-metadata.yaml`, copying the compute pair with port 8005 and the path `/.well-known/oauth-protected-resource/registry/mine`, then apply it. Check it from the laptop:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -d '{}' http://localhost:8080/registry/mine        # 401
   curl -s http://localhost:8080/.well-known/oauth-protected-resource/registry/mine | jq .       # resource and Keycloak issuer
   ```

4. **Find it from the client.** Add an entry next to the lab ones in `~/.codex/config.toml`, then sign in from a normal terminal, not inside a Codex chat:

   ```toml
   [mcp_servers.lab-mine]
   url = "http://localhost:8080/registry/mine"
   scopes = ["openid", "profile"]

   [mcp_servers.lab-mine.oauth]
   client_id = "codex-mcp"
   callback_url = "http://127.0.0.1:5555/callback"
   ```

   ```bash
   codex mcp login lab-mine
   ```

   In Codex, `lab-registry`'s `list_servers` now includes `my-inventory`, and `lab-mine` lists its tools. Claude Code or any other MCP client with OAuth sign-in would use the same URL. That has not been tested here.

5. **Call a tool as dev-user.** dev-user gets `list_vms`, `get_vm` and `get_cost_by_vm` on `/registry/mine`. The tool a developer isn't allowed to use, `restart_vm`, does not appear. A call to `list_vms` for eu-london-1 returns `checkout-api-01` and `checkout-api-02`.

To remove it again: `arctl delete -f my-deployment.yaml`, `arctl delete -f my-mcpserver.yaml`, take the `mine` rule and the `mine-prm` backend back out of `yaml/oauth-metadata.yaml`, re-apply it, delete the `mine-prm` backend with kubectl and stop the process on 8005.

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

One agent only: no calls from one agent to another and no kagent AccessPolicies. Also out: token exchange to the upstream clouds, and a single merged `/mcp` across servers (that needs hand-written agentgateway config, which the registry does not generate). TLS is off everywhere because this is a laptop demo.
