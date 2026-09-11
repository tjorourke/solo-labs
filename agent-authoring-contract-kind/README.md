# agent-authoring-contract-kind

Part 1 of **Writing agents for kagent**, a five-part series. This part builds no agent.
It makes the contract between kagent and an agent visible, by driving a running agent
with curl: the agent card, `message/send`, the `message/stream` frames, and the task
the UI reads back out of the controller's store. Parts 2 to 5 implement that contract
as a declarative agent, in Python, in Go and in Java.

The series shares one question, put to a seeded namespace with four broken pods:
*"Which pods in sre-lab are unhealthy, and why?"*

## What it needs

An existing cluster. Nothing here creates one.

- Solo Enterprise for kagent (tested on 0.4.3), with a `default-model-config` ModelConfig
  and its API key Secret in the `kagent` namespace
- Solo Enterprise for agentgateway (tested on v2026.8.2), for the waypoint in front of the
  tool server
- Istio ambient with the `kagent` namespace enrolled (`istio.io/dataplane-mode=ambient`),
  which is what gives the waypoint the agent's identity
- The `kagent-tools` Deployment kagent installs by default, used as the tool server
- `kubectl`, `curl`, `python3`

If the controller is protected by OIDC, the scripts mint a token from Keycloak (the
defaults match a cluster set up with the vision-demo scripts: realm `agentregistry`,
client `kagent-cli-password`, user `admin-user`). Without `KEYCLOAK_URL` the scripts look for Keycloak behind the ingress Gateway named by
`KEYCLOAK_GATEWAY` (default `ar-ingress` in `KEYCLOAK_GATEWAY_NS`, default
`agentgateway-system`) at `keycloak.<gateway address>.sslip.io`. Override with `KEYCLOAK_URL`,
`KEYCLOAK_REALM`, `KEYCLOAK_CLIENT`, `AS_USER`, `AS_PASSWORD`, or set `KAGENT_TOKEN`.

## Bring it up

```bash
export CTX=kind-mesh1            # any context with the prerequisites above
./scripts/quick.sh up
```

`up` seeds the `sre-lab` namespace, puts an agentgateway waypoint, a per-agent tool
policy and an L4 authorization in front of `kagent-tools`, registers the `sre-tools`
catalogue entry, and deploys `sre-reference`, a declarative agent used as the far end
of the contract.

## Drive the contract

```bash
./scripts/show-card.sh sre-reference                 # GET /.well-known/agent-card.json
./scripts/send-message.sh sre-reference "Which pods in sre-lab are unhealthy, and why?"
./scripts/stream-message.sh sre-reference "Which pods in sre-lab are unhealthy, and why?"
./scripts/ask.sh sre-reference "Which pods in sre-lab are unhealthy, and why?"
./scripts/read-tasks.sh <session id printed by ask.sh>
```

`send-message.sh` and `stream-message.sh` go to the agent's own pod; nothing is stored.
`ask.sh` goes through the controller with a session, which is what makes the turn a
conversation the kagent UI lists. `read-tasks.sh` reads what the UI reads.

## The four checks

```bash
./scripts/check-agent.sh sre-reference
```

1. Ready: the card is served.
2. Stored: a turn through the controller leaves a task with the question first and the
   answer last.
3. Gateway: the agent's identity gets exactly four read tools through the waypoint and
   is reset when it goes to `kagent-tools` directly.
4. Identity: the waypoint log carries the agent's SPIFFE identity.

Every later part ends with the same script against its own agent.

## Files

| path | what |
|---|---|
| `yaml/00-sre-namespace.yaml` | the seeded namespace: 3 healthy, 4 broken, frozen |
| `yaml/10-sre-tools-gateway.yaml` | Service + waypoint Gateway + MCP Backend + HTTPRoute in front of kagent-tools |
| `yaml/20-tool-policy.yaml` | which tools each agent identity may call |
| `yaml/30-tools-authz.yaml` | ztunnel refuses the agents' direct route to kagent-tools:8084 |
| `yaml/40-sre-tools-remotemcpserver.yaml` | the catalogue entry, pointing at the waypoint |
| `yaml/50-reference-agent.yaml` | the declarative agent this part drives |
| `scripts/lib.sh` | shared by every part: context, controller, token, sessions |
| `scripts/platform.sh` | the shared pieces, idempotent, called by every part |
| `scripts/ask.sh`, `check-agent.sh` | shared by every part |

## Teardown

```bash
./scripts/quick.sh teardown      # the agent and the shared pieces; other parts' agents stay
```
