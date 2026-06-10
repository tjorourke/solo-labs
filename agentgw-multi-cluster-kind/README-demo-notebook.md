# Running the `agentgateway-enterprise-demo` notebook against this lab

This lab (`agentgw-multi-cluster-kind`) is a superset of what
[rvennam/agentgateway-enterprise-demo](https://github.com/rvennam/agentgateway-enterprise-demo)
needs. Once `quick.sh` finishes, the cluster has:

- Solo Enterprise agentgateway **v2026.5.1** (latest GA, calver scheme — succeeds v2.3.x)
  with `tokenExchange.enabled=true` so the built-in STS responds on
  `enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777`
  (notebook §7).
- Solo Enterprise `management` chart on `kind-east-ag`: ClickHouse,
  `solo-enterprise-ui` (Service the notebook §9 references by name),
  agentevals, and the OTel telemetry collectors.
- Bitnami **Keycloak** in namespace `keycloak`, realm `solo`, with two
  clients:
  - `kagent` — public, password grant (for users `alice` / `bob` / `carol`).
  - `agentgw-demo` — confidential, client-credentials grant. Used by the
    notebook's §7-§8 to mint a service token. Client secret is the
    fixed-dev value `dev-secret-do-not-use-in-prod` (see
    `yaml/keycloak/realm-solo.json`).

`init-demo.sh` finishes the wiring: creates the `agentgateway-proxy`
Gateway the notebook expects, opens a Keycloak port-forward on
`localhost:18080`, and writes a Keycloak-populated `~/.auth0.env` so the
notebook's setup cell loads as-is.

## Quick start

```bash
# 1. Stand up the cluster (one-time, ~15-20 min)
cd /path/to/solo-demos/agentgw-multi-cluster-kind
./scripts/quick.sh

# 2. Wire the demo notebook against this cluster
./scripts/init-demo.sh

# 3. Bootstrap the notebook's workloads (mock-llm, httpbin, server-everything, STS)
cd /path/to/agentgateway-enterprise-demo
./init.sh

# 4. Open the notebook
source ~/.venvs/jupyter/bin/activate
jupyter notebook demo.ipynb
```

`init-demo.sh down` tears down the Gateway / port-forward / `~/.auth0.env`
without touching the cluster.

## The one notebook patch you need

The notebook is written for Auth0. Keycloak's OIDC token endpoint sits at
a different path. **One** line in §8 cell 53 needs to change:

```diff
-    AUTH0_TOKEN=$(curl -sS -X POST "https://$AUTH0_DOMAIN/oauth/token" \
+    AUTH0_TOKEN=$(curl -sS -X POST "http://$AUTH0_DOMAIN${AUTH0_TOKEN_PATH:-/oauth/token}" \
```

Two things changed on that line:

| Was | Now | Why |
|---|---|---|
| `https://` | `http://` | `kubectl port-forward svc/keycloak 18080:80` is plain HTTP. |
| `/oauth/token` | `${AUTH0_TOKEN_PATH:-/oauth/token}` | Keycloak's token endpoint is `/realms/<realm>/protocol/openid-connect/token`. `init-demo.sh` exports `AUTH0_TOKEN_PATH` to that path; the `:-` fallback keeps the cell compatible with a real Auth0 tenant if you ever swap `~/.auth0.env` back. |

Everything else in the notebook works unmodified — `AUTH0_DOMAIN`,
`AUTH0_AUDIENCE`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET` are all set
by `init-demo.sh` to Keycloak-equivalent values, and the OAuth2
client-credentials shape Keycloak speaks matches what the notebook
sends.

## Why not just use Auth0?

You can — swap `~/.auth0.env` for one with real Auth0 values, drop the
notebook patch above, and `init-demo.sh`'s port-forward + the Keycloak
install become dead weight (harmless). The Keycloak path is here because
it runs entirely on the kind cluster: no signup, no internet round-trips,
no shared tenant.

## What gets installed where

| Cluster | Component | Namespace |
|---|---|---|
| `kind-east-ag` (CLUSTER1) | Enterprise agentgateway control + data plane | `agentgateway-system` |
| `kind-east-ag` | Solo Enterprise management (ClickHouse + UI + telemetry) | `agentgateway-system` |
| `kind-east-ag` | Keycloak (bitnami chart) | `keycloak` |
| `kind-east-ag` | `agentgateway-proxy` Gateway (created by `init-demo.sh`) | `agentgateway-system` |
| `kind-east-ag` | rate-limiter + Redis (auto-deployed by AGW controller per Gateway) | `agentgateway-system` |
| `kind-west-ag` (CLUSTER2) | Enterprise agentgateway (peer cluster for multicluster lab) | `agentgateway-system` |

The notebook only uses CLUSTER1. CLUSTER2 is idle while the notebook
runs — it's still up so this same lab supports the multicluster labs
(`agentgw-cloud-connectivity`, `agentgw-agentic-mcp`).

## Env-var escape hatches on `quick.sh`

| Var | Effect |
|---|---|
| `SKIP_SOLO_MGMT=true` | Skip the Solo management chart (ClickHouse + UI). Notebook §9 won't have a UI to point at. |
| `SKIP_KEYCLOAK=true` | Skip Keycloak. You'd need to supply Auth0 (or some other OIDC issuer) yourself. |
| `AGW_NIGHTLY=true` | Swap the AGW chart + image registry to the private nightly dev registry. `AGW_VERSION_NIGHTLY` overrides the pinned dev tag. |
| `SOLO_MGMT_VERSION=…` | Override the management-chart version (default `0.4.3`). |
