# AgentRegistry end to end, part 3: approved MCP tools, two runtimes, and tool-level AccessPolicy

A developer builds an agent with `arctl`, pulls in **approved MCP tool servers** from the
registry catalog, publishes it, and deploys the *same* agent to two runtimes — Solo
Enterprise for **kagent** (local kind) and **AWS Bedrock AgentCore**. A platform owner then
restricts which MCP tools the agent may call with a kagent **AccessPolicy**, enforced at an
**agentgateway waypoint**.

The walkthrough runs in **`demo.ipynb`**. This README is the one-time engineer setup you do
first. Run everything from this lab directory.

## Prerequisites
- Docker running; an **Anthropic API key** and Solo licenses (`SOLO_LICENSE_KEY` for kagent,
  `SOLO_ISTIO_LICENSE_KEY` + `AGENTGATEWAY_LICENSE_KEY` for the waypoint).
- `gcloud auth login` (Solo charts + images pull over OCI/GAR).
- *AgentCore add-on only:* an AWS account with an SSO profile in `~/.aws/config`.

Everything else (kind, kubectl, helm, jq, yq, uv, aws, `arctl`) is installed by step 2.

## Run it

```bash
# 1. capture credentials (prompts for each; secrets hidden; AWS profile picker)
./scripts/setup-env.sh

# 2. bring up the platform: kind + Keycloak + kagent + arctl daemon + the two MCP
#    servers + the dice skill + the agentgateway waypoint data plane (~20 min first run)
./scripts/setup.sh
```

Then open **`demo.ipynb`** (Bash kernel) and run it top to bottom. To open the consoles
(AgentRegistry UI + kagent UI) in a terminal: `./scripts/open-consoles.sh`.

## Layout
- `demo.ipynb` — the customer-facing walkthrough.
- `scripts/` — numbered setup steps (`00`–`05`), the per-demo helpers (`add-mcp.sh`,
  `accesspolicy-on.sh`/`-off.sh`, `ask.sh`, `open-consoles.sh`), and `lib.sh`.
- `mcp/` — the two MCP tool servers (`everything-server`, `my-mcp`).
- `skill/` — the `dice-game` skill.
- `yaml/`, `kind/`, `templates/` — manifests, kind config, the Bedrock model adapter.

## The AccessPolicy demo

```bash
./scripts/accesspolicy-on.sh    # deny the printenv tool at the waypoint (least privilege)
./scripts/accesspolicy-off.sh   # restore the full tool list
```

## Reset / teardown

```bash
./scripts/reset.sh      # back to start: clears agentdemo/, deployments; platform stays up
./scripts/cleanup.sh    # full teardown (cluster, daemon, registry, AWS)
```
