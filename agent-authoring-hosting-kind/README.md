# Hosting an agent and containing its tools

Part 6 of **Writing agents for kagent**. Restrict tool and A2A access by workload
identity, route model requests through a waypoint, and test selected network paths.
These controls run outside the model. They do not provide a process sandbox or
prove that data cannot leave through a permitted dependency.

For the motivation, read the [OpenAI and Hugging Face incident guide](https://mastertheagent.com/solo/zero-trust-agents-kubernetes/).
An allowed service's outbound capabilities also belong in the agent's threat model.

[Source in solo-labs](https://github.com/tjorourke/solo-labs/tree/main/agent-authoring-hosting-kind).
Clone `https://github.com/tjorourke/solo-labs.git` and run from this directory with
`agent-authoring-contract-kind/` beside it.

## Agents

| Agent | Role | Access |
| --- | --- | --- |
| sre-caller | Receives the user's question | Delegates to sre-contained |
| sre-contained | Investigates pods | Four approved Kubernetes read tools |
| sre-other | Tests denied access | No tools from the protected endpoint; A2A denied |

All three use the model waypoint. The MCP policy separately allows the controller
service account for discovery and the same tool grants. Ask `sre-caller` in the UI:
direct controller calls to `sre-contained` are intentionally denied by its A2A policy.

## Prerequisites

An existing cluster with Solo Enterprise for kagent, Enterprise agentgateway,
Istio ambient and the `kagent` namespace enrolled; the `kagent-anthropic` Secret;
an ingress Gateway; Keycloak; and a network plugin that enforces NetworkPolicy.
The scripts require kubectl, curl and Python 3. Part 1's setup is applied by `up`.
The operator running the namespace-scope test needs permission to create and
delete a temporary namespace, service account and probe pod.

Do not assume NetworkPolicy enforcement from the existence of the resource. Record
the plugin/version and compare positive and negative probes on your own cluster.
The observed cluster used kindnetd `v20251212-v0.29.0-alpha-105-g20ccfc88`,
Kubernetes v1.35.0 and Istio ambient. A direct Anthropic request succeeded from an
unselected declarative pod but timed out from `sre-contained`.

## Run

```bash
export CTX=kind-mesh1
./scripts/quick.sh up
../agent-authoring-contract-kind/scripts/ask.sh sre-caller "Which pods in sre-lab are unhealthy, and why?"
../agent-authoring-contract-kind/scripts/ask.sh sre-other "Which pods in sre-lab are unhealthy, and why?"
./scripts/quick.sh test
```

Use the same user in the UI as the token used by `ask.sh`. The permitted caller
receives a delegated report; the other caller receives a denial.

## Policy boundaries

- A waypoint protects a destination Service. Callers can share it with different
  permissions. Separate proxies are a deployment choice, not a per-agent requirement.
- Tool grants match namespace and service account. Pods sharing those values share
  the workload identity. Tool names do not restrict namespace/resource arguments;
  enforce those through the tool implementation and its Kubernetes RBAC.
- The egress policy allows **the entire kagent namespace on all ports**, plus DNS,
  istiod and telemetry. This is a lab allowance, not a gateway-only rule. Other
  matching NetworkPolicies can add access. Narrow selectors/ports for your environment.
- Direct Anthropic and tool-server connections are probed; required model calls
  still reach Anthropic through the waypoint. Review indirect access through all
  allowed services. The ModelConfig still references the agent's model-key Secret.

## Optional external-client exercise

Setup creates a route on the existing local ingress listener, protected by JWT
authentication and a demo-user tool allowlist. Defaults: `INGRESS_GATEWAY=ar-ingress`,
`INGRESS_GATEWAY_NS=agentgateway-system`. Keycloak settings follow Part 1's helpers.

```bash
./scripts/call-edge.sh
./scripts/quick.sh render-edge  # inspect the rendered route and policies
```

The default URL uses HTTP for this local kind demonstration. Before carrying tokens
outside that setup, configure an HTTPS listener with a trusted certificate and
use `EDGE_URL=https://tools.example.com/mcp`. This override changes only the client
URL, not the Gateway configuration. Validate the intended issuer/audience and
replace the demo `admin-user` rule with application-specific grants.

## Endpoint audit

```bash
./scripts/audit-endpoints.sh
./scripts/audit-endpoints.sh --json
./scripts/audit-endpoints.sh --path /another-mcp-path
python3 scripts/test-audit-endpoints.py
```

The audit inventories Gateways and Gateway-attached HTTPRoutes, plus non-ClusterIP
Services in `NS` (default `kagent`). It probes unauthenticated MCP initialize on
concrete hostnames with agentgateway backends, using HTTP/HTTPS listener ports.

| Verdict | Meaning |
| --- | --- |
| ACCEPTED | MCP initialize succeeded without credentials; tool access is not established |
| DENIED | This request received HTTP 401 or 403 |
| INCONCLUSIVE | Network/TLS failure, timeout, redirect or unexpected response |
| NOT_TESTED | Outside probe scope; no authentication assumption is made |

Other paths, wildcard/unspecified hostnames, other route types and exposure outside
Gateway API need separate review. Findings do not change the report's exit code;
inventory/API errors fail the command. The lab checks explicitly assert DENIED for
this lab's route. A zero ACCEPTED count is not an all-clear for the cluster.

## Files

- `yaml/10-model-egress.yaml`, `20-model-config.yaml`: fixed model upstream and base URL.
- `yaml/30-tools-endpoint.yaml`, `40-tools-policy.yaml`: protected MCP endpoint and grants.
- `yaml/50-agent.yaml`, `55-other-agent.yaml`, `90-a2a.yaml`: agents and A2A caller policy.
- `yaml/60-edge-route.yaml`: local ingress route and JWT/tool policies.
- `yaml/70-egress-policy.yaml`, `80-tools-authz.yaml`: network allowances and direct-tool denial.
- `scripts/check.sh`: selected live access checks.
- `scripts/probe-other-namespace.sh`: same service-account name in a temporary
  ambient namespace, with cleanup after the probe.
- `scripts/audit-endpoints.py`: inventory, probe selection and request verdicts.
- `scripts/test-audit-endpoints.py`: verdict regression tests without a cluster.

## Cleanup

`./scripts/quick.sh teardown` removes Part 6 resources; Part 1's shared pieces stay.
Use the same ingress overrides as setup. Before deploying beyond the lab, review
destination scope, data permissions, HTTPS, credentials and runtime isolation;
the full walkthrough and incident guide explain these separately.
