# kagent-quickstart-kind

**The kagent companion to `agentgateway-quickstart-kind`. From an empty cluster to a working,
governed, observable Solo Enterprise for kagent, step by step — every step mapped to the docs.**

The walkthrough is the lab page (`index.html`), published on
[mastertheagent.com](https://mastertheagent.com/). It runs on `kind` here, but the same
commands work on any Kubernetes cluster: point `kubectl` at it and skip the cluster step.

This lab is **kagent only** — no AgentRegistry. It installs Solo Enterprise for kagent,
runs an MCP tool server, deploys agents two ways (declarative and BYO / ADK), governs their
tools with AccessPolicies, shows traces in the UI, and (Beta) runs an agent in a gVisor
Sandbox.

## What it covers

1. **Install**: kagent-enterprise CRDs + controller + the Solo Enterprise UI, by Helm, behind Keycloak
2. **MCP**: run an MCP tool server and register it as a kagent `MCPServer`
3. **Declarative agent**: a kagent `Agent` CRD wired to the MCP tools
4. **BYO / ADK**: bring your own agent (Google ADK) and host it on kagent
5. **AccessPolicies**: govern which tools an agent may call
6. **Observability**: agent traces in the Solo Enterprise UI
7. **SandboxAgent** (Beta): run an agent as an actor in a gVisor sandbox

## Prerequisites

- `kubectl`, `helm`, `kind`
- `SOLO_LICENSE_KEY` (Solo Enterprise for kagent)
- `ANTHROPIC_API_KEY` (the model provider used here)

## Status

Built and verified section by section on kind (kagent-enterprise v0.5.2). Versions are
recorded in the page's **Versions** footer.
