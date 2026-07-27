# agentgateway-quickstart-kind

**The first lab to give a customer. From an empty cluster to a working, secured, observable Solo Enterprise for agentgateway, step by step, every step mapped to the official docs.**

The walkthrough is the lab page (`index.html`), published at
[mastertheagent.com](https://mastertheagent.com/). It runs on `kind` here, but the
exact same commands work on **any** Kubernetes cluster: point `kubectl` at it and skip
the cluster-creation step. The manifests it applies ship in `yaml/` so you can
`kubectl apply -f` them directly.

## What it covers

A checklist at the top of the page tracks the six sections, each with its doc link:

1. **Install**: Gateway API CRDs + agentgateway CRDs + control plane + UI, all by Helm ([docs](https://docs.solo.io/agentgateway/latest/install/helm/), [UI](https://docs.solo.io/agentgateway/latest/install/ui/setup/))
2. **IdP**: Keycloak, the OIDC identity provider ([docs](https://docs.solo.io/agentgateway/latest/security/jwt/))
3. **Configure**: a `Gateway` and an `HTTPRoute` to a sample app ([docs](https://docs.solo.io/agentgateway/latest/traffic-management/))
4. **MCP**: expose an MCP tool server through the gateway ([docs](https://docs.solo.io/agentgateway/latest/mcp/static-mcp/))
5. **Observability**: metrics, traces, access logs in the UI ([docs](https://docs.solo.io/agentgateway/latest/observability/))
6. **Cost management**: model cost catalog, dimensions, and the cost dashboard ([docs](https://docs.solo.io/agentgateway/latest/llm/cost-controls/cost-tracking/))

## Prerequisites

- `kubectl` and `helm`
- `kind` (only if you want the throwaway cluster; not needed on an existing cluster)
- `AGENTGATEWAY_LICENSE_KEY` for the Enterprise pieces (UI, MCP, cost management). Ask your Solo account team for a trial key.

## Create the cluster

```bash
kind create cluster --name agw-quickstart
export CTX=kind-agw-quickstart
```

On an existing cluster, skip the create and just set your context:

```bash
export CTX=$(kubectl config current-context)
```

## Run it

```bash
export AGENTGATEWAY_LICENSE_KEY=<your-trial-key>
```

Then open the lab page (`index.html`) and follow the steps top to bottom, or apply the
manifests in `yaml/` and run the Helm commands from the page yourself.

## Notes

- **Keycloak is the upstream image** (`quay.io/keycloak/keycloak`, dev mode, in-memory, realm imported from a ConfigMap), the same pattern used across the Solo labs. It is deliberately **not** a Bitnami Helm chart: those images now sit behind Broadcom's paywall/legacy registry, so a Helm-for-Keycloak path leads to `ImagePullBackOff`.
- **Install and the UI are Helm**, verbatim from the official docs.
- Everything reaches the gateway / UI / Keycloak over `kubectl port-forward`, so no LoadBalancer or ingress is required.

## Teardown

```bash
kind delete cluster --name agw-quickstart
```

## Files in this lab

The full walkthrough (with the Helm commands) is the lab page. The manifests it applies are here so you can `kubectl apply -f` them directly:

- `yaml/keycloak/`: Keycloak Deployment + the `solo` realm (users alice/bob/carol, client `kagent`)
- `yaml/gateway/httpbin-route.yaml`: sample app + `Gateway` + `HTTPRoute`
- `yaml/mcp/mcp.yaml`: MCP tool server + `EnterpriseAgentgatewayBackend` + route
- `yaml/cost/cost-catalog.yaml`: model cost catalog + `EnterpriseAgentgatewayParameters`
