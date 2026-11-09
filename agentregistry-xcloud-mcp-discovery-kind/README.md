# Calling MCP servers outside your cluster through agentregistry and agentgateway

Tested live on 9 Nov 2026. Solo Enterprise for agentregistry 2026.10.0 and Solo Enterprise for agentgateway v2026.10.2 only. Standalone kind cluster `xcloud-mcp`. No OSS edition: the Virtual runtime that writes the gateway config is an Enterprise agentregistry feature.

## The story

A platform team looks after MCP servers that run in different places. One in cloud-a reports compute instances and one in cloud-b reports spend. Neither runs in the platform team's cluster. Developers want to use them from their coding agent without hunting for URLs, and the platform team wants every call to go through one gateway with a real sign-in and control over which tools each developer gets.

What each step shows:

| Step | What you do | What you see |
|---|---|---|
| 1 | Start two MCP servers outside the cluster | Two containers on the kind Docker network, one per "cloud" |
| 2 | Catalogue them in agentregistry by URL | `arctl get mcp` lists both |
| 3 | Deploy them through the Virtual runtime | The registry writes the agentgateway backends and a `/registry/<name>` child route. `status.runtime.endpoint` shows the URL |
| 4 | Put Keycloak sign-in on the gateway | No token gives 401. The protected-resource metadata points MCP clients at Keycloak |
| 5 | Hide one tool from developers | `restart_instance` drops out of `tools/list` for dev-user and returns 400 if called by name |
| 6 | Discover from Codex | Codex asks the read-only registry MCP which servers exist and where |
| 7 | Sign in from Codex and call tools | `codex mcp login lab-cloud-a` opens Keycloak, then Codex calls cloud-a through the gateway |

## How the pieces fit

```
 Laptop                                 kind cluster xcloud-mcp                      Outside the cluster
 ------                                 -----------------------                      -------------------
 Codex ── lab-registry ── :31313 ──▶ agentregistry (registry MCP, read-only)
   │                                        │ writes backends + child routes
   │                                        ▼
   └──── lab-cloud-a ──── :8080 ───▶ agentgateway  /registry/cloud-a ─────────▶  ext-mcp-cloud-a (FastMCP)
                                       JWT policy  /registry/cloud-b ─────────▶  ext-mcp-cloud-b (FastMCP)
 Browser ── sign-in ───── :8180 ───▶ Keycloak (realm agentregistry)
```

Codex discovers through the registry MCP (`list_deployments` returns the gateway endpoint), then connects to the gateway URL. On the first call the gateway answers 401 with a pointer to its protected-resource metadata. That metadata names Keycloak as the authorisation server, so Codex sends the browser straight to Keycloak and comes back with a token for audience `mcp-gateway`.

The policy leaves out `mcp.provider`. With `provider: Keycloak` the gateway rewrites the authorisation server issuer to its own URL, Keycloak still returns its own `iss`, and Codex rejects the mismatch. That is agentgateway issues #3668 and #3635. The fix, PR #3637, was not merged on 22 Oct 2026. Without `provider` the issuer stays Keycloak's and there is nothing to mismatch. The price is that Keycloak needs a pre-registered client (`codex-mcp`) because the gateway no longer proxies dynamic client registration.

Keycloak has one URL everywhere, because tokens carry `iss` and both the gateway and the registry check it. The laptop reaches Keycloak through a port-forward on 8180 and pods reach it through its Service, so both use `http://keycloak.127.0.0.1.nip.io:8180`. On the laptop nip.io resolves that name to 127.0.0.1. In the cluster a CoreDNS rewrite sends it to the Keycloak Service. Keycloak's `KC_HOSTNAME` pins the issuer to that URL.

## Before you start

Docker, kind, kubectl, Helm 3.12 or later, curl, jq, Python 3, `envsubst` (gettext), OpenAI Codex CLI 0.165 or later, and `arctl` 2026.10.0:

```bash
curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh | ARCTL_VERSION=v2026.10.0 sh
export PATH=$HOME/.arctl/bin:$PATH
```

Licences come from your local secrets file, never the repo:

```bash
set -euo pipefail
set +x
source "${SECRETS_FILE:-$HOME/.solo/secrets.env}"
: "${AGENTGATEWAY_LICENSE_KEY:?Set AGENTGATEWAY_LICENSE_KEY in the secrets file}"
: "${AGENTREGISTRY_LICENSE_KEY:?Set AGENTREGISTRY_LICENSE_KEY in the secrets file}"
kind get clusters
```

If `xcloud-mcp` already exists, stop. Don't replace it.

```bash
kind create cluster --config kind/cluster.yaml
export CTX=kind-xcloud-mcp
```

## 1. Start two MCP servers outside the cluster

`mcp-servers/server.py` is one small FastMCP server. `CLOUD=cloud-a` gives `list_instances`, `get_instance` and `restart_instance`. `CLOUD=cloud-b` gives `monthly_spend` and `top_services`. The data is fixed so the demo does the same thing every time.

```bash
docker build -t xcloud-mcp-server:lab mcp-servers
docker run -d --name ext-mcp-cloud-a --network kind -e CLOUD=cloud-a xcloud-mcp-server:lab
docker run -d --name ext-mcp-cloud-b --network kind -e CLOUD=cloud-b xcloud-mcp-server:lab
export CLOUD_A_HOST=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' ext-mcp-cloud-a)
export CLOUD_B_HOST=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' ext-mcp-cloud-b)
echo "$CLOUD_A_HOST $CLOUD_B_HOST"
```

They are registered by IP. Whether pods resolve Docker container names on the kind network hasn't been checked, so the lab doesn't rely on it.

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

The Solo install guide passes the licence with `--set licensing.licenseKey=...`. `--set-file` with a process substitution keeps it out of the process list. If your Helm rejects that, use the guide's form.

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

Sign `arctl` in as the platform admin, then create the runtime, the two catalogue entries and the two Deployments:

```bash
export OIDC_ISSUER=http://keycloak.127.0.0.1.nip.io:8180/realms/agentregistry
arctl user login --oidc-flow=password-credentials --oidc-client-id=ar-cli-password \
  --oidc-username=admin-user --oidc-password=password
arctl apply -f - < registry/runtime.yaml
envsubst '${CLOUD_A_HOST} ${CLOUD_B_HOST}' < registry/mcpservers.yaml | arctl apply -f -
arctl apply -f - < registry/deployments.yaml
arctl apply -f - < registry/rbac.yaml
```

```yaml
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: cloud-a-compute
spec:
  title: Cloud A compute inventory
  description: "Instances and their state in cloud-a. Hosted outside the cluster."
  remote:
    type: streamable-http
    url: http://${CLOUD_A_HOST}:8000/mcp
---
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: cloud-a
spec:
  targetRef:
    kind: MCPServer
    name: cloud-a-compute
    tag: latest
  runtimeRef:
    kind: Runtime
    name: mcp-gateway
  runtimeConfig:
    route:
      pathSuffix: /cloud-a
    backend:
      mcp:
        authorization:
          action: Allow
          policy:
            matchExpressions:
              - '!jwt.Groups.exists(g, g == "developers")'
              - 'mcp.tool.name != "restart_instance"'
```

`action: Allow` lets a call through when any expression is true. Admins get every tool. Developers get everything except `restart_instance`. cloud-b has no tool policy. The full files are in [registry/](registry/). `rbac.yaml` gives the `developers` group read access to the catalogue so dev-user can use the registry MCP.

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

The registry's child route only matches `/registry/cloud-a`, but a client looks for `/.well-known/oauth-protected-resource/registry/cloud-a`. [yaml/oauth-metadata.yaml](yaml/oauth-metadata.yaml) adds a small route and MCP backend for that path so the gateway can answer it. This is the one piece of gateway config the platform team writes per server they want Codex to sign in to.

```bash
envsubst '${CLOUD_A_HOST}' < yaml/oauth-metadata.yaml | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" apply --dry-run=server -f yaml/jwt-policy.yaml
kubectl --context "$CTX" apply -f yaml/jwt-policy.yaml
kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaypolicies
```

Check it from the laptop:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{}' http://localhost:8080/registry/cloud-a
curl -s http://localhost:8080/.well-known/oauth-protected-resource/registry/cloud-a | jq
```

The first prints `401`. The second should show `resource` as `http://localhost:8080/registry/cloud-a` and `authorization_servers` as the Keycloak issuer. If `resource` is anything else, fix it before going near Codex.

## 7. Prove the tool filter with curl

```bash
eval "$(./scripts/mint-token.sh dev-user)"
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $LAB_MCP_TOKEN")
SID=$(curl -s -D - -o /dev/null "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0.1"}}}' \
  http://localhost:8080/registry/cloud-a | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' http://localhost:8080/registry/cloud-a
curl -s "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' http://localhost:8080/registry/cloud-a | grep -o '"name":"[a-z_]*"'
curl -s -o /dev/null -w '%{http_code}\n' "${H[@]}" -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restart_instance","arguments":{"name":"web-02"}}}' \
  http://localhost:8080/registry/cloud-a
```

dev-user sees `list_instances` and `get_instance` only. Calling `restart_instance` by name gives `400`. The gateway answers with JSON-RPC error -32602 "unknown resource" and no 403, so a developer can't tell the tool exists. Repeat with `./scripts/mint-token.sh admin-user` and `restart_instance` is back.

## 8. Run it with Codex

Needs Codex 0.167.0 or later (`codex --version`) and the port-forwards up (`./scripts/quick.sh port-forward`). If any of them drop (for example after a pod restart), run `./scripts/quick.sh stop-port-forward && ./scripts/quick.sh port-forward`.

Show the change first. Nothing is written until you run `apply`, which makes a timestamped backup of `~/.codex/config.toml`. It touches nothing else.

```bash
./scripts/codex-config.sh show
./scripts/codex-config.sh apply
codex mcp list        # lab-cloud-a: Not logged in   lab-registry: Bearer token
```

```toml
mcp_oauth_callback_port = 5555

[mcp_servers.lab-registry]
url = "http://localhost:31313/mcp"
bearer_token_env_var = "LAB_AR_TOKEN"

[mcp_servers.lab-cloud-a]
url = "http://localhost:8080/registry/cloud-a"
scopes = ["openid", "profile"]

[mcp_servers.lab-cloud-a.oauth]
client_id = "codex-mcp"
callback_url = "http://127.0.0.1:5555/callback"
```

`mcp_oauth_callback_port` is a top-level key, so the script puts it above your first `[table]` and the two server tables at the end, each inside marker comments. `remove` takes out only what is between the markers.

**Registry discovery (`lab-registry`).** The registry MCP on 31313 takes a bearer token for a registry user. A Keycloak dev-user token works, and so does an `arctl` session token. `mint-token.sh` prints export lines, so eval it rather than wrapping it in `$(...)`. Start Codex from the same shell, because Codex reads `LAB_AR_TOKEN` when it starts:

```bash
eval "$(./scripts/mint-token.sh dev-user)"   # sets LAB_AR_TOKEN and LAB_MCP_TOKEN; Keycloak tokens last 5 minutes
```

**Sign in to cloud-a (browser):**

```bash
codex mcp login lab-cloud-a
```

Keycloak's agentregistry realm opens. Sign in as `dev-user`, with the password from `yaml/keycloak-realm.yaml` (users, dev-user, credentials). Keycloak sends you back to `http://127.0.0.1:5555/callback`, the redirect registered for the `codex-mcp` client. `codex mcp list` then shows lab-cloud-a as signed in.

Tested live on 9 Nov 2026. The browser sign-in as dev-user completed end to end and `codex mcp list` then showed lab-cloud-a as signed in.

After sign-in, `list_instances` through lab-cloud-a returned `web-01`, `web-02` and `batch-07`, and Codex picked out `web-02` as the only stopped instance in eu-west. Asked to restart `web-02`, Codex found no restart tool, because dev-user's `tools/list` only has `list_instances` and `get_instance`. The denied tool stays hidden and does not return an error. With `admin-user`'s token, `tools/list` on `/registry/cloud-a` includes `restart_instance`. `monthly_spend` on `/registry/cloud-b` (no tool policy there) returned a figure for dev-user with no filtering.

`codex exec`, the non-interactive form used to script this, needs `--approve-for-me`. Without it the MCP tool calls are denied under its default `never` approval policy. The interactive `codex` that this lab uses doesn't have this problem.

Checked without signing in (9 Nov 2026):
- An unauthenticated call to `/registry/cloud-a` returns `401`, with `resource_metadata` pointing to `/.well-known/oauth-protected-resource/registry/cloud-a`.
- That document names the Keycloak realm issuer and scopes `openid profile`.
- Keycloak's metadata advertises `authorization_response_iss_parameter_supported: true` and S256 PKCE, so Codex keeps the configured callback.
- Keycloak accepts `http://127.0.0.1:5555/callback` for `codex-mcp` and rejects any other port.

**Try it:**

```bash
codex
```

- "Use lab-registry to list the MCP servers and deployments. Which endpoints do they have?" (`list_servers`, `list_deployments`: cloud-a-compute and cloud-b-costs, at `/registry/cloud-a` and `/registry/cloud-b`)
- "Use lab-cloud-a to list the instances. Which are stopped in eu-west?" (`list_instances` through the gateway)
- "Restart web-02." (dev-user has no such tool, so Codex can't call it)

The approved Codex block doesn't add cloud-b. Try `monthly_spend` with curl instead:

```bash
source scripts/lib.sh; eval "$(./scripts/mint-token.sh dev-user)"
s=$(mcp_init "$GW_LOCAL/registry/cloud-b" "$LAB_MCP_TOKEN")
mcp_rpc "$GW_LOCAL/registry/cloud-b" "$LAB_MCP_TOKEN" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"monthly_spend","arguments":{"month":"2026-10"}}}'
```

**Bearer fallback.** If the browser sign-in fails on stage, switch cloud-a to a pasted token. The gateway runs the same check without the browser:

```bash
./scripts/codex-config.sh bearer             # lab-cloud-a uses bearer_token_env_var = "LAB_MCP_TOKEN"
eval "$(./scripts/mint-token.sh dev-user)"
codex
./scripts/codex-config.sh oauth              # back to Keycloak sign-in
```

Remove the lab entries afterwards with `./scripts/codex-config.sh remove`.

## Scripts

Optional shortcuts. The steps above are the lab.

- `./scripts/quick.sh up` builds everything above and leaves it running. Refuses an existing `xcloud-mcp` cluster.
- `./scripts/quick.sh test` checks the curl path end to end and prints PASS or FAIL per check.
- `./scripts/quick.sh port-forward` and `stop-port-forward` start and stop the three laptop port-forwards.
- `./scripts/demo.sh` walks the live demo one command at a time.
- `./scripts/codex-config.sh show|apply|bearer|oauth|remove`.

Only after review:

```bash
./scripts/codex-config.sh remove
CONFIRM_TEARDOWN=xcloud-mcp ./scripts/quick.sh teardown
```

Teardown deletes the cluster and the two containers, then checks they are really gone. Nothing tears down on exit or on failure.

## What this lab doesn't cover

Agent-to-agent calls through kagent, token exchange to the upstream clouds, and a single merged `/mcp` across servers (that needs hand-written agentgateway config, which the registry does not generate). TLS is off everywhere because this is a laptop demo.
