# agent-authoring-go-kind

Part 4 of **Writing agents for kagent**. Build the SRE triage agent with kagent's Go
ADK and deploy a compiled image. The program configures the model and tools;
the ADK handles the agent card, A2A requests and controller-backed sessions.

[Browse the files in solo-labs](https://github.com/tjorourke/solo-labs/tree/main/agent-authoring-go-kind).
Clone `https://github.com/tjorourke/solo-labs.git` and run commands from
`agent-authoring-go-kind/`. Keep `agent-authoring-contract-kind/` alongside it.

Previous: [Part 3, Python on the kagent ADK](../agent-authoring-python-kind/).
Next: [Part 5, Java, with the contract written by hand](../agent-authoring-java-kind/).

## Prerequisites

An existing cluster, selected with `CTX`, running:

- Solo Enterprise for kagent (tested on 0.4.3), with a `default-model-config`
  ModelConfig and the `kagent-anthropic` Secret in the `kagent` namespace
- enterprise agentgateway (tested on v2026.8.2)
- an ambient mesh with the `kagent` namespace enrolled
- the `kagent-tools` Deployment kagent ships, used as the tool server

On the machine: `docker`, `kubectl`, `curl`, `python3`, and a registry the cluster
pulls from (`localhost:5001` on kind by default; set `IMAGE` to push elsewhere). No Go
toolchain: the Dockerfile's build stage has it.

The shared pieces (the seeded `sre-lab` namespace, the `sre-tools` waypoint, the
per-agent tool policy and the L4 authorization) come from
[Part 1](../agent-authoring-contract-kind/) and are applied by `quick.sh up`.

## Run it

```bash
export CTX=kind-mesh1
./scripts/quick.sh up        # Part 1 pieces, build + push the image, deploy sre-go, wait Ready
./scripts/quick.sh test      # the four checks
../agent-authoring-contract-kind/scripts/ask.sh sre-go "Which pods in sre-lab are unhealthy, and why?"
./scripts/quick.sh teardown  # remove the agent; the shared pieces stay for the other parts
```

If the controller is protected by OIDC the scripts mint a token from the cluster's
Keycloak (see `lib.sh` in Part 1) or use `KAGENT_TOKEN` if set.

## Files

| path | what it is |
|---|---|
| `src/main.go` | the wiring: config, model, agent, kagent's executor, the app |
| `src/agent.go` | the LlmAgent: system prompt, Anthropic model, MCP toolsets, the local tool |
| `src/tools.go` | the health gate as a local function tool |
| `src/env.go` | every environment variable the agent reads, in one struct |
| `src/Dockerfile` | two stages, a 14 MB static image |
| `yaml/sre-go.yaml` | the BYO Agent resource |
| `scripts/build.sh` | build and push the image |
| `scripts/quick.sh` | up, test, teardown |

## What to look at

- `kubectl -n kagent get agent sre-go`: Ready once the card is served.
- The pod's environment: kagent injects `KAGENT_NAME`, `KAGENT_NAMESPACE`, `KAGENT_URL`
  and the `OTEL_*` variables, and mounts a projected token at
  `/var/run/secrets/tokens/kagent-token`. The library reads all of them.
- The kagent UI: the conversation opened by `ask.sh` is listed under the agent and is
  still there after navigating away, because the library stored the task.
- The `sre-tools-waypoint` log: every tool call carries
  `src.identity=spiffe://<trust-domain>/ns/kagent/sa/sre-go`.
