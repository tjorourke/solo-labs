# agentregistry-arctl-kind

**AgentRegistry end to end, part 1.** The full AgentRegistry lifecycle with
`arctl`, end to end on a kind cluster (part 2 covers registry governance:
AccessPolicies, per-team visibility, and approval flows):

1. `arctl init` scaffolds the three artifact kinds: the **textkit** MCP server
   (FastMCP, `word_count` + `extract_links`), the **summary-style** skill, and
   the **summarizer** agent (ADK Python, Anthropic `claude-haiku-4-5`).
2. `arctl run` proves the agent + MCP + skill together locally, no cluster.
3. `arctl build --push` builds the scaffolded Dockerfiles into OCI images and
   pushes them to a local registry (`localhost:5001`).
4. `arctl apply` publishes all three artifacts to the AgentRegistry catalog.
5. A Kubernetes `Runtime` + AgentRegistry `Deployment` host the agent on
   **Solo Enterprise for kagent**, and the hosted agent is tested through the
   controller's OIDC-protected A2A endpoint with a real Keycloak token.

Full write-up with captured output:
https://www.masterthemesh.com/solo/agentregistry-arctl-kind/

## Run it

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SOLO_LICENSE_KEY=...            # Solo Enterprise for kagent

./scripts/quick.sh up                  # cluster → keycloak → kagent → daemon
                                       #   → scaffold check → build/publish → deploy

./scripts/ask.sh "summarize this: <paste text with a couple of links>"

./scripts/test-local.sh                # no-cluster inner loop (arctl run)
./scripts/quick.sh status
./scripts/quick.sh teardown
```

## Layout

- `scripts/` — numbered setup steps plus `quick.sh` (orchestrator) and
  `ask.sh` (mint alice's Keycloak token, call the agent over A2A).
- `artifacts/` — the three `arctl init` projects: `textkit/` (MCP),
  `summary-style/` (skill), `summarizer/` (agent).
- `yaml/` — the AgentRegistry `Runtime`/`Deployment` shapes and the Keycloak
  install (realm `solo`, users alice/bob/carol).
- `kind/` — the cluster config.
