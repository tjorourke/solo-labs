# agent-harness-openclaw-kind

Run exact OpenClaw 2.0 (v2026.8.1) in Docker, then run OpenClaw as a kagent
`AgentHarness` on Agent Substrate with its model path and one MCP tool path
through agentgateway. The lab is about where responsibility moves when a
complete agent harness becomes a managed platform workload.

Write-up: https://mastertheagent.com/solo/agent-harness-openclaw-kind/

## What gets built

```
Docker (host)
└── OpenClaw 2026.8.1-browser        gateway container, Control UI on 127.0.0.1:18789

kind cluster openclaw-harness (1 control plane + 1 worker, kindest/node:v1.35.0)
├── ate-system      Agent Substrate 0.0.9: ate-api-server, ate-controller, atelet,
│                   atenet-router, Valkey, rustfs
├── kagent          kagent OSS 0.10.1, controller.substrate.enabled=true
│   ├── WorkerPool kagent-default        2 x ateom-gvisor:v0.0.9
│   ├── AgentHarness openclaw-lab        backend: openclaw  -> ActorTemplate -> gVisor actor
│   ├── SandboxAgent workspace-reference the small kagent-native comparison
│   ├── ModelConfig agentgateway-model   OpenAI-compatible, baseUrl = the gateway
│   └── kagent-tools                     124 tools, reached only through the gateway
├── agentgateway-system   agentgateway OSS v1.5.0
│   ├── Gateway openclaw-gateway
│   ├── /v1   AgentgatewayBackend anthropic (key in anthropic-secret)
│   └── /mcp  AgentgatewayBackend kagent-tools + AgentgatewayPolicy: 4 read tools
└── sre-lab         7 workloads, 4 broken on purpose
```

## Prerequisites

`docker`, `kind`, `kubectl`, `helm`, `python3`, `git`. An Anthropic API key.
About 8 vCPU and 16 GB free for the Substrate stack; the baseline alone is much
smaller. Tested on an arm64 laptop with OrbStack.

```bash
export ANTHROPIC_API_KEY=sk-ant-...      # or put it in $SECRETS_FILE
```

## Run it

```bash
./scripts/quick.sh baseline   # OpenClaw 2.0 alone in Docker, plus its five tests
./scripts/quick.sh up         # cluster, Substrate, kagent, harness, agentgateway, MCP
./scripts/ask.sh "Which pods in sre-lab are unhealthy, and why? Do not make changes."
./scripts/quick.sh test       # the PASS/FAIL table
./scripts/quick.sh ui         # kagent UI on http://localhost:18080
./scripts/quick.sh status     # harness, template, actors, workers
./scripts/quick.sh teardown
```

`up` runs `scripts/01-cluster.sh` to `06-mcp.sh` in order; each is idempotent
and can be rerun alone. `ask.sh` speaks ACP to the harness through the kagent
controller (`scripts/acp.py`, standard library only); add `--approve` to answer
OpenClaw's permission requests with allow-once, and `--capture NAME` to save the
raw JSON-RPC frames under `captures/`.

## Layout

```
versions.env          every pin in one place
kind/cluster.yaml
yaml/
  10-kagent-values.yaml            substrate integration, two gVisor workers
  20-openclaw-harness.yaml         the AgentHarness, direct ModelConfig
  30-reference-sandbox-agent.yaml  the comparison SandboxAgent
  40-gateway.yaml                  agentgateway Gateway
  41-anthropic-backend.yaml        Anthropic backend + /v1 route
  42-model-config.yaml             placeholder Secret + ModelConfig on the gateway
  43-openclaw-harness-gateway.yaml the harness on that ModelConfig
  50-sre-lab.yaml                  the namespace the harness is asked about
  51-tools-backend.yaml            kagent-tools behind /mcp
  52-tools-policy.yaml             the four-tool allow-list
scripts/
  quick.sh  lib.sh  00-baseline.sh  01-cluster.sh ... 06-mcp.sh  check.sh
  ask.sh  acp.py  mcp-list.py  baseline-test.py  approval-test.py  *.mjs
openclaw/workspace/   AGENTS.md, MEMORY.md and the lab-inspector skill seeded into the baseline
captures/             outputs from the run the article was written from
spikes/version-contract.md   what the pinned builds actually did
```

## Things to know before changing it

- kagent and Agent Substrate are a pair. kagent's `go.mod` pins the Substrate
  module; bump both together and rerun `quick.sh test`.
- kagent's OpenClaw backend image pins its own OpenClaw (2026.5.27 in 0.10.1).
  The exact 2.0 run is the Docker baseline.
- The harness's one shared actor keeps the config it was created with. To move
  the model path (`modelConfigRef`) the scripts delete and re-create the
  `AgentHarness`; the workspace inside the actor is lost with it.
- `ModelConfig` for the gateway is `provider: OpenAI`. With `provider: Anthropic`
  and an explicit `baseUrl`, kagent 0.10.1 writes a model slot without
  `maxTokens` and OpenClaw's Anthropic transport refuses every turn.
- The MCP registry entry is written with `openclaw mcp set` inside the actor,
  over ACP. kagent 0.10.1 has no `AgentHarness` field for it.
- Never mount `$HOME`, SSH keys or a personal browser profile into the baseline;
  everything it writes lives under `.runtime/` here.
