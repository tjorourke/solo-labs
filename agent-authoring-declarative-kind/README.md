# agent-authoring-declarative-kind

Part 2 of *Writing agents for kagent*. Configure the SRE triage agent as
`type: Declarative` and compare the Python and Go runtimes. The manifest selects
the model and tools and supplies the system prompt; kagent handles A2A and task
storage. No custom container image is required.

[Browse the files in solo-labs](https://github.com/tjorourke/solo-labs/tree/main/agent-authoring-declarative-kind).
Clone `https://github.com/tjorourke/solo-labs.git` and run commands from
`agent-authoring-declarative-kind/`. Keep `agent-authoring-contract-kind/` alongside it.

Two agents from the same manifest:

- **sre-declarative**: kagent's Python runtime (the default).
- **sre-declarative-go**: the same spec with `spec.declarative.runtime: go`, on kagent's
  Go runtime.

## Prerequisites

An existing cluster with:

- Solo Enterprise for kagent (tested on 0.4.3) with a `default-model-config` ModelConfig
  in the `kagent` namespace
- enterprise agentgateway (tested on v2026.8.2), for the waypoint in front of the tools
- an Istio ambient mesh with the `kagent` namespace enrolled
  (`istio.io/dataplane-mode=ambient`)
- Part 1 of the series (`agent-authoring-contract-kind`) checked out next to this
  directory: it holds the shared scripts, the seeded `sre-lab` namespace and the
  `sre-tools` waypoint, policy and catalogue entry that every part uses

Tools on the workstation: `kubectl`, `curl`, `python3`.

## Run it

```bash
export CTX=kind-mesh1                 # the kubectl context to use
./scripts/quick.sh up                 # Part 1's platform pieces, then both agents, waits for Ready
./scripts/quick.sh test               # the four checks against each agent
./scripts/quick.sh teardown           # removes this part's two agents only
```

The controller API is reached through a port-forward and, on Solo Enterprise for kagent,
with an OIDC token. The shared `lib.sh` mints one from the cluster's Keycloak; set
`KAGENT_TOKEN` to supply your own, or `KEYCLOAK_URL`, `KEYCLOAK_REALM`,
`KEYCLOAK_CLIENT`, `AS_USER` and `AS_PASSWORD` to use another Keycloak configuration.

## Inspect the running agents

```bash
S=../agent-authoring-contract-kind/scripts
$S/show-card.sh sre-declarative            # the card each runtime serves (try sre-declarative-go)
$S/stream-message.sh sre-declarative "Which pods in sre-lab are unhealthy, and why?"
                                           # the SSE frames the runtime emits, one line each
$S/ask.sh sre-declarative "Which pods in sre-lab are unhealthy, and why?"
                                           # a turn through the controller, filed in a session the UI lists
$S/check-agent.sh sre-declarative-go       # Ready, stored, gateway-only, identity
```

Open the kagent UI, pick either agent, and the conversation `ask.sh` opened is there
under the token's user, with the tool calls drawn as cards.

## Files

| file | what it is |
|---|---|
| `yaml/sre-declarative.yaml` | the agent on the Python runtime |
| `yaml/sre-declarative-go.yaml` | the same agent on the Go runtime (`runtime: go`, `deployment.imageRegistry: ghcr.io`) |
| `scripts/quick.sh` | `up`, `test`, `teardown` for this part; everything else is shared from Part 1 |
