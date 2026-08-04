# agentic-verdict-hitl-kind — imposing HITL on an agent the developer built

A developer builds two SRE agents with `arctl`. They are the same agent twice.
An external review process decides one of them is higher risk. The platform team
puts a human in front of that agent's actions, and the developer is never
involved: no code change, no rebuild, no republish, and nothing the developer can
switch off.

Single kind cluster, Solo Enterprise throughout: **agentgateway 2026.7.1**,
**kagent Enterprise 0.5.3**, **Enterprise AgentRegistry 2026.6.1**.

## The question this answers

> Without trusting the developer to add human-in-the-loop, how does a platform
> team add it, based on a decision made somewhere else, at build time?

Three mechanisms, applied together, all keyed off one verdict:

| # | Mechanism | What it does | Is it a control? |
|---|---|---|---|
| 1 | **Kyverno rewrites `MCP_SERVERS_CONFIG`** | Red agent's tool traffic is redirected from `/mcp` to `/mcp-gated` at admission | Yes, it decides the path |
| 2 | **`extAuth` on the gated route** | Every call across `/mcp-gated` parks until a human decides | **Yes. This is the gate.** |
| 3 | **`prompt.prepend` on a restricted AI backend** | Injects a system message into every model request | **No.** Advisory only |

Mechanism 3 is in the lab specifically so you can watch it *not* be a control. A
system prompt changes what the model tends to do; it stops nothing. Pair it with
2 or it is decoration.

## The thing that surprised me

`requireApproval` is the obvious answer and it does not work here.

The kagent `Agent` CRD has both `spec.declarative` and `spec.byo`. `requireApproval`
lives at `spec.declarative.tools[].mcpServer.requireApproval`. But `spec.byo`
contains **only** `deployment` — no tool list, nowhere to put it. An agent from
`arctl init agent --framework adk` deploys as `type: BYO`, its ADK tool loop runs
inside its own container, and kagent never sees the individual tools.

So for an agent scaffolded by `arctl`, the native kagent approval card is not
reachable. The gateway is the only place platform-imposed HITL can live. Which is
the better architecture anyway: HITL belongs at the gateway precisely because the
agent's internals are not yours to edit.

(If you want the native card, the agent has to be `Declarative` and the developer
has to have declared its tools. That is a different lab.)

## Topology

```
      developer                        platform team
      ─────────                        ─────────────
  arctl init agent  ×2
  arctl build --push ×2
  arctl apply       ×2  ──► AgentRegistry ──► kagent controller
                                                  │
                                        Kyverno admission webhook
                                        reads the risk register
                                                  │
                        ┌─────────────────────────┴──────────────────────┐
                        │                                               │
                   green: untouched                            red: rewritten
                        │                                               │
              MCP_SERVERS_CONFIG                          MCP_SERVERS_CONFIG
                  .../mcp                                    .../mcp-gated
                                                     + ANTHROPIC_API_BASE
                        │                                               │
                        ▼                                               ▼
        ┌───────────────────────────── agentgateway ─────────────────────────────┐
        │  /mcp          no policy                                              │
        │  /mcp-gated    EnterpriseAgentgatewayPolicy.traffic.extAuth  ──────────┼──► hitl-extauth :9001
        │  llm.<LB>      EnterpriseAgentgatewayBackend  ai.prompt.prepend        │      (parks Check())
        └───────────────────────────────┬───────────────────────────────────────┘            │
                                        ▼                                                    │
                              sre-tools MCP server                        hitl-ui ◄── poll ──┘
                              (one tool set, no idea                      (approve / reject)
                               who is calling)
```

## The verdict

Written to one ConfigMap. That is the entire integration surface for whatever
review process you already trust:

```bash
kubectl -n kyverno create configmap agent-risk-register \
  --from-literal=red="sreremediate" \
  --from-literal=lb="172.18.255.200"
```

Keyed by a `red` list rather than per-agent keys because Kyverno ConfigMap lookups
with a dynamic key need nested `{{ }}` interpolation, which is fragile.
`contains(split(...))` is exact-match and stable.

`default` sets the posture for anything not named. `default: red` gates every agent
unless it has been explicitly cleared, which is the correct direction for a
control:

```bash
VERDICT_DEFAULT=red ./scripts/07-verdict.sh    # deny-by-default platform
```

It is a ConfigMap and not a label on the Agent CR for one reason: **the policy has
to fire on CREATE.** If the verdict were a label stamped after AgentRegistry
created the CR, the red agent would be live and completely ungated for the seconds
between creation and labelling. For a security control that is a hole.

## The policy has tests

It is the control, so it gets a real test rather than a read-through. Offline, no
cluster, via the Kyverno CLI:

```bash
brew install kyverno
./scripts/test-policy.sh
```

Four postures plus an idempotence check. Run it after any edit to
`yaml/kyverno/20-verdict-hitl.yaml`.

It has already earned its keep: the first run found that with the register absent,
every agent resolved to green, so a missing ConfigMap silently ungated the whole
cluster. That is what the `default` key and the bootstrap register in phase 04
fix.

## Run it

Needs `ANTHROPIC_API_KEY`, `SOLO_LICENSE_KEY`, and `gcloud auth login` (the
Enterprise charts are in a private GAR).

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SOLO_LICENSE_KEY=...
# or: SECRETS_FILE=/path/to/secrets.sh

./scripts/quick.sh up        # ~15-20 min cold
./scripts/quick.sh status    # which agent is gated, and how each is wired
```

Then drive the comparison:

```bash
# the green agent diagnoses and fixes, unattended
./scripts/ask.sh sretriage "checkout is unhealthy — diagnose and fix it"

# the red agent diagnoses, then stops and waits for you
./scripts/ask.sh sreremediate "checkout is unhealthy — diagnose and fix it"
```

While the red agent waits, open the approval queue at `http://hitl.<LB>.sslip.io`
(the URL is printed by `status`), or decide from the CLI:

```bash
./scripts/quick.sh pending
./scripts/quick.sh approve     # or: reject
```

Change who is red and re-run:

```bash
VERDICT_RED="sretriage,sreremediate" ./scripts/07-verdict.sh   # gate both
VERDICT_RED="" ./scripts/07-verdict.sh                          # gate neither
```

## Layout

| Path | What |
|---|---|
| `scripts/01-cluster.sh` | kind + local registry + MetalLB + Gateway API |
| `scripts/02-agentgateway.sh` | agentgateway 2026.7.1 + ingress Gateway, writes `.env.verdict` |
| `scripts/03-keycloak.sh` | Keycloak + the `agentregistry` realm, scrapes client secrets |
| `scripts/04-kagent-registry.sh` | kagent Enterprise + AgentRegistry + Kyverno |
| `scripts/05-mcp-and-hitl.sh` | MCP server, approval gate, both routes, the HITL policy |
| `scripts/06-agents.sh` | **the developer's phase** — build, publish, deploy both agents |
| `scripts/07-verdict.sh` | **the platform team's phase** — the verdict lands |
| `scripts/ask.sh` | talk to either agent over kagent's OIDC-protected A2A endpoint |
| `scripts/quick.sh` | `up` / `status` / `pending` / `approve` / `reject` / `reset` / `down` |
| `artifacts/AGENT_TEMPLATE.py` | the single source for BOTH agents — do not edit the copies |
| `artifacts/sretriage/`, `artifacts/sreremediate/` | the two `arctl init` projects |
| `src/sre-tools/` | Python MCP server, mock cluster with one OOM-looping workload |
| `src/hitl-extauth/` | Go ext-auth gRPC service that parks `Check()` |
| `src/hitl-ui/` | Go HTMX approval queue |
| `yaml/kyverno/20-verdict-hitl.yaml` | **the control** — the mutation that imposes HITL |
| `yaml/agentgateway/20-hitl-policy.yaml` | the gate — `extAuth`, attached by label |
| `yaml/agentgateway/30-restricted-llm.yaml` | the advisory layer — `ai.prompt.prepend` |

## Things worth knowing before you change it

Full detail in [CLAUDE.md](./CLAUDE.md). The short list:

- **`arctl init agent` rejects hyphens.** Agent names are lowercase letters and
  digits only, so `sre-triage` is not a legal name. Hence `sretriage`.
- **Never `patchStrategicMerge` an env list on the kagent Agent CRD.** There is no
  merge key for `spec.byo.deployment.env`, so a strategic merge replaces the whole
  list and silently wipes the registry-injected MCP wiring and the model key. Use
  `patchesJson6902`. Labels are a map, so a strategic merge is fine there.
- **`phase: PreRouting` cannot target an HTTPRoute.** A CEL rule on the CRD limits
  it to Gateway, ListenerSet, Service and ServiceEntry. Route-scoped extAuth runs
  at the default `PostRouting`, which still gates before the backend call.
- **`ANTHROPIC_API_BASE` is not enough on its own.** LiteLLM honours it on the
  text-completion and `/models` paths but not on the `/v1/messages` chat path that
  ADK uses, so the template reads it and passes `api_base` explicitly. Relying on
  env discovery alone sends traffic to `api.anthropic.com` while looking correct.
- **`failureMode: FailClosed`** on the gate is not optional. A HITL gate that fails
  open when the approver is down is not a gate.

## Status

Built and statically validated: every script passes `bash -n`, every manifest
parses, every Python file compiles, and all CRD blocks pass the repo's
`lint-crd-blocks.py` against the cached agentgateway schemas.

**Not yet run end to end on a live cluster.** The Enterprise install needs a
licence and GAR access, so the run is a separate step; `lab-tested-versions.json`
carries no entry for this lab until it has actually been driven. Treat the version
pins as intended, not as validated.
