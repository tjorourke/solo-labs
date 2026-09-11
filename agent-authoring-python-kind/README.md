# agent-authoring-python-kind

Part 3 of *Writing agents for kagent*: the same Kubernetes SRE triage agent as the
rest of the series, written in Python on Google ADK and hosted by kagent's own Python
runtime (`kagent-adk`). The agent is one directory of Python: a model, an instruction,
one local tool and the MCP tools kagent hands it. The A2A server, the streamed frames,
the session and the stored task the UI reads are all the runtime's.

Series: [Part 1, the contract](../agent-authoring-contract-kind/) ·
[Part 2, declarative](../agent-authoring-declarative-kind/) · **Part 3, Python** ·
[Part 4, Go](../agent-authoring-go-kind/) · [Part 5, Java](../agent-authoring-java-kind/)

## What it needs

An existing cluster, not a new one:

- Solo Enterprise for kagent (the controller, a `default-model-config` ModelConfig, the
  bundled `kagent-tools` server) in namespace `kagent`.
- Enterprise agentgateway, for the waypoint Part 1 puts in front of the tool server.
- An ambient mesh with the `kagent` namespace enrolled, so the agent's identity reaches
  that waypoint.
- A Secret `kagent-anthropic` holding `ANTHROPIC_API_KEY`.
- Part 1 checked out next to this directory (`../agent-authoring-contract-kind`): its
  `platform.sh` seeds the `sre-lab` namespace and applies the tool gateway, and its
  `ask.sh` and `check-agent.sh` are what this part runs.
- On the machine: `docker`, `kubectl`, `curl`, `python3`, and a registry the cluster
  pulls from at `localhost:5001` (a kind cluster with a local registry).

If the controller is protected by OIDC, `lib.sh` mints a token from the Keycloak behind
the `ar-ingress` gateway; set `KAGENT_TOKEN` to supply one instead.

## Run it

```bash
export CTX=kind-mesh1                  # the kubectl context to use
./scripts/quick.sh up                  # Part 1's shared pieces, then build, push, deploy
../agent-authoring-contract-kind/scripts/ask.sh sre-python "Which pods in sre-lab are unhealthy, and why?"
./scripts/quick.sh test                # the four checks
./scripts/quick.sh teardown            # removes sre-python only
```

`up` builds `src/` into `localhost:5001/sre-python:lab`, pushes it, applies
`yaml/sre-python.yaml` and waits for the Agent to be Ready. A rebuild (`scripts/build.sh`)
restarts the running Deployment onto the new image and compares digests.

## The files

| file | what it is |
|---|---|
| `src/sretriage/agent.py` | the agent: model from `MODEL_PROVIDER`/`MODEL_NAME`, the instruction, the tools |
| `src/sretriage/gate.py` | the health rule as a local tool the model calls |
| `src/sretriage/mcp.py` | one `MCPToolset` per server in `MCP_SERVERS_CONFIG` |
| `src/sretriage/agent-card.json` | the card the runtime serves at `/.well-known/agent-card.json` |
| `src/Dockerfile` | the kagent runtime image plus the package |
| `yaml/sre-python.yaml` | the `Agent`, `type: BYO`, with the environment the runtime reads |
| `scripts/build.sh` | build, push, restart, compare digests |
| `scripts/quick.sh` | `up`, `test`, `teardown` |

## The four checks

`./scripts/quick.sh test` runs Part 1's `check-agent.sh sre-python`: the card is served
and the agent is Ready; a turn through the controller leaves a task in the session
store with the question first and the answer last; the agent's identity gets exactly
the four read tools through the waypoint and is reset by ztunnel when it goes to
`kagent-tools` directly; the waypoint log carries `spiffe://<trust domain>/ns/kagent/sa/sre-python`.
