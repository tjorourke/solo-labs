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
> team add it, based on a decision made somewhere else?

One verdict in a ConfigMap, imposed by one Kyverno policy at admission. Both agent
types end up at **kagent's own approval flow** — the same card, the same API. What
differs is only the field the policy has to set, which follows from `spec.type`:

| Agent type | kagent sees | What the policy sets | Approve via |
|---|---|---|---|
| **Declarative** (ADK on kagent's runtime) | the tool list | `requireApproval` on the tool stanza | Solo Enterprise UI, or the kagent A2A API |
| **BYO** (`arctl init agent`) | a pod | `KAGENT_REQUIRE_APPROVAL` in the pod env | the same UI, the same API |

`requireApproval` lives on the tool list and `spec.byo` has no tool list — just
`deployment`. So for a BYO agent the policy sets an environment variable instead, and
the agent's own ADK toolsets turn it into `require_confirmation`. ADK then emits the
same `adk_request_confirmation` that kagent renders. **Nothing extra runs**: no
gateway gate, no approval service, no second MCP route.

`declarative.runtime` is "which ADK implementation to use", so a Declarative agent is
still an ADK agent — you give up owning the image, not the framework. Prefer it when
you can; use BYO for opaque containers or an image you must build yourself.

Neither the agents nor the MCP server know which tools are sensitive. That judgement
is the platform team's, and it lives in the register.

## Topology

```
   developer                                    platform team
   ─────────                                    ─────────────
 arctl init agent ×2 ─► AgentRegistry ─┐
 kubectl apply (declarative) ──────────┤
                                       ▼
                            kagent controller
                                       │
                       Kyverno admission webhook
                     reads configmap/agent-risk-register
                       red / default  +  gated (per MCP server)
                                       │
                       matched against THIS agent's own servers
                    Declarative: mcpServer.toolNames
                    BYO:         MCP_SERVERS_CONFIG
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │ Declarative + red            │ BYO + red                    │ green
        ▼                              ▼                              ▼
  + requireApproval          + KAGENT_REQUIRE_APPROVAL            untouched
  (from the register)          (from the register)                     │
        │                              │                              │
        └──────────────┬───────────────┘                              │
                       ▼                                              ▼
                kagent pauses the tool                     tools run straight through
                       │
        ┌──────────────┴───────────────┐
        ▼                              ▼
  Solo Enterprise UI            kagent A2A API
  Approve / Reject              message/send + function_response
                       │
                       ▼
              sre-tools MCP server
              (one endpoint, one tool set,
               no idea who is calling)
```

Everything the agents reach goes through agentgateway: the MCP route, Keycloak, the
AgentRegistry API and the Enterprise UI. No policy sits in front of the MCP server —
a call that arrives there has already been approved.

## The verdict

Written to one ConfigMap. That is the entire integration surface for whatever
review process you already trust:

```bash
kubectl -n kyverno create configmap agent-risk-register \
  --from-literal=red="sreremediate,srenative" \
  --from-literal=default="green" \
  --from-literal=gated='- server: sre-tools
  tools:
    - restart_deployment
    - scale_deployment'
```

Three keys, and between them the whole decision:

| key | what it answers |
| --- | --- |
| `red` | which agents need a human. `*` = every agent, so the register gates on tools alone |
| `default` | the answer for anything not named; set `red` for deny-by-default |
| `gated` | which tools need approval, per MCP server. `tools: ["*"]` gates every tool a server exposes, including ones it has not shipped yet |

`red: "*"` is the mode worth knowing about: no agent is ever named, so any agent that
can call a gated tool needs a human, whoever built it and whenever it arrives. The tool
list is still resolved per agent, so an agent that uses none of the gated servers is
untouched. Broad in agents, narrow in tools.

The control works in both directions. Clearing `red`, or dropping a server from `gated`,
**removes** the mutation from agents that already carry it. Without that the agent keeps
pausing while labelled green — safe, and a lie. That is four `ungate-*` rules rather than
a condition on the existing ones, because Kyverno's preconditions are a flat
`all`/`any` and cannot express "out of scope *or* nothing gated" in one rule.

**No tool name appears in the policy.** Adding the hundredth tool, or a whole new MCP
server, is a ConfigMap edit. That separation is the point: the policy is cluster-wide
admission control, so editing it is a change-managed event, while adding a register
entry is not.

Addresses are not in here either. There is one MCP route and every agent uses it, so
there is nothing to keep in sync and the same policy works on any cluster.

Keyed by a `red` list rather than per-agent keys because Kyverno ConfigMap lookups
with a dynamic key need nested `{{ }}` interpolation, which is fragile.
`contains(split(...))` is exact-match and stable. The `gated` lookup avoids the same
trap by being a **list filtered by a substituted value**, not a map indexed by one:
`{{ element.mcpServer.name }}` is resolved before the JMESPath runs.

## The policy has tests

It is the control, so it gets a real test rather than a read-through. Offline, no
cluster, via the Kyverno CLI:

```bash
brew install kyverno
./scripts/test-policy.sh
```

Two matrices plus an idempotence check, over both agent types:

- **posture** — who gets gated, under which `red`/`default` combination
- **register** — *which* tools get gated, including the wildcard, a register entry
  naming a tool the agent does not have, a server the agent does not use, and an
  empty register

The second matrix matters most, because the policy names no tool. If the register
lookup breaks, the policy still applies cleanly and still labels every agent red, and
gates nothing — a silent fail-open. So it is asserted directly rather than inferred
from the policy applying without error.

Run it after any edit to `yaml/kyverno/20-verdict-hitl.yaml`. The harness also checks
its own rule names against the policy: a stale name there is not a test failure, it is
an untested policy, because Kyverno leaves the stubbed context unresolved and every
assertion then fails for the wrong reason.

It earned its keep on the first run: with the register absent, every agent resolved
to green, so a missing ConfigMap silently ungated the whole cluster. That is what the
`default` key and the bootstrap register in phase 04 fix.

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

Then drive it. Same prompt, three agents:

```bash
# green BYO agent: diagnoses and fixes, unattended
./scripts/ask.sh sretriage "checkout is unhealthy — diagnose and fix it"

# red BYO agent: diagnoses, then its change parks at the GATEWAY
./scripts/ask.sh sreremediate "checkout is unhealthy — diagnose and fix it"
./scripts/quick.sh pending
./scripts/quick.sh approve          # or: reject

# red DECLARATIVE agent: approval belongs to kagent, not the gateway
./scripts/approve.sh srenative "restart the checkout deployment in shop" approve
./scripts/approve.sh srenative "restart the checkout deployment in shop" reject
```

`approve.sh` makes the same A2A call the kagent UI makes when you click Approve: a
follow-up `message/send` on the paused task with a `function_response` data part
setting `confirmed`. There is no separate approvals REST endpoint. Or just open the
kagent UI and click — `quick.sh status` prints the URL.

Change who needs approval, without touching an agent:

```bash
kubectl -n kyverno patch configmap agent-risk-register \
  --type merge -p '{"data":{"red":"sretriage,sreremediate,srenative"}}'

# deny-by-default: every agent needs approval unless explicitly cleared
kubectl -n kyverno patch configmap agent-risk-register \
  --type merge -p '{"data":{"default":"red"}}'
```

The policy runs when the Agent resource is written, so an already-running agent needs
to pass through admission again to pick up a change:

```bash
kubectl -n kagent annotate agent sreremediate \
  risk.platform.solo.io/reviewed-at="$(date +%s)" --overwrite
```

In a real pipeline the register is read at first deploy and there is no extra step.
`./scripts/07-verdict.sh` does both for you.

## Layout

| Path | What |
|---|---|
| `scripts/01-cluster.sh` | kind + local registry + MetalLB + Gateway API |
| `scripts/02-agentgateway.sh` | agentgateway 2026.7.1 + ingress Gateway, writes `.env.verdict` |
| `scripts/03-keycloak.sh` | Keycloak + the `agentregistry` realm, scrapes client secrets |
| `scripts/04-kagent-registry.sh` | kagent Enterprise + AgentRegistry + Kyverno |
| `scripts/05-mcp.sh` | the sre-tools MCP server and its route |
| `scripts/06-agents.sh` | **the developer's phase** — build, publish, deploy both agents |
| `scripts/07-verdict.sh` | **the platform team's phase** — the verdict lands |
| `scripts/ask.sh` | talk to any agent over kagent's OIDC-protected A2A endpoint |
| `scripts/approve.sh` | approve/reject a pending call over the kagent A2A API — the same call the UI makes |
| `scripts/quick.sh` | `up` / `status` / `reset` / `down` |
| `artifacts/AGENT_TEMPLATE.py` | the single source for BOTH agents — do not edit the copies |
| `artifacts/sretriage/`, `artifacts/sreremediate/` | the two `arctl init` projects |
| `src/sre-tools/` | Python MCP server, mock cluster with one OOM-looping workload |
| `yaml/kyverno/05-rbac.yaml` | lets Kyverno read Gateway API resources |
| `yaml/kyverno/20-verdict-hitl.yaml` | **the control** — one policy, both agent types, no tool names |
| `yaml/agents/declarative-native.yaml` | the kagent-native variant (Declarative + `requireApproval`) |
| `yaml/agentgateway/10-mcp-routes.yaml` | the one MCP route every agent uses |
| `scripts/test-policy.sh` | the policy's offline test matrix (Kyverno CLI) |

## Things worth knowing before you change it

Full detail in [CLAUDE.md](./CLAUDE.md). The short list:

- **`arctl init agent` rejects hyphens.** Agent names are lowercase letters and
  digits only, so `sre-triage` is not a legal name. Hence `sretriage`.
- **Never `patchStrategicMerge` an env list on the kagent Agent CRD.** There is no
  merge key for `spec.byo.deployment.env`, so a strategic merge replaces the whole
  list and silently wipes the registry-injected MCP wiring and the model key. Use
  `patchesJson6902`. Labels are a map, so a strategic merge is fine there.
- **`ANTHROPIC_API_BASE` is not enough on its own.** LiteLLM honours it on the
  text-completion and `/models` paths but not on the `/v1/messages` chat path that
  ADK uses, so the template reads it and passes `api_base` explicitly. Relying on
  env discovery alone sends traffic to `api.anthropic.com` while looking correct.
- **Gate the tools that change state, not the reads.** Gating everything sounds safer
  and is worse: the agent cannot run `list_pods` without an approval, the reviewer is
  buried in read-only requests, and the ones that matter get rubber-stamped along with
  the rest. Gating reads trains the reviewer to click yes. This is why the register is
  a per-server tool list and not a per-agent boolean.
- **Intersect the register's tools with the agent's own `toolNames`.** A CEL rule on
  the Agent CRD requires every `requireApproval` entry to appear in `toolNames`, so a
  register naming a tool this agent lacks makes the API server reject the whole
  resource and the deploy fails. Intersecting is also what lets one register cover a
  fleet with different tool sets.
- **Match tool names exactly.** `contains()` against a comma-joined string lets an
  entry called `scale` gate `scale_deployment` — the same class of bug as matching
  `sre` against `sreremediate` in the red list. The policy compares against a JMESPath
  list literal instead.
- **`require_confirmation` gets the tool's ARGUMENTS, not its name.** ADK invokes the
  callable form with the tool's own arguments plus `tool_context`, so one callable
  cannot tell which tool it is being asked about. The template splits each server into
  a gated and an ungated `MCPToolset` and uses `tool_filter` for membership, which is
  where the tool name is actually available.
- **A `:latest` agent image with `imagePullPolicy: IfNotPresent` will not be re-pulled.**
  AgentRegistry sets that policy, so a rebuilt-and-pushed image is invisible: the pod
  comes up healthy on OLD code and nothing reports a problem. This bit us for real — the
  green agent's image was left behind by a template change, and because a green agent's
  gating path is never exercised the drift stayed hidden until the register was switched
  to `red: "*"`, at which point the agent was correctly mutated, carried the right env
  var, and still did not gate. `06-agents.sh` now evicts the layer from every node,
  forces a rollout, and diffs the file in each running pod against the one it built.
- **Never leave `ANTHROPIC_API_BASE` pointing at a route that no longer exists.**
  The agent dies with `AnthropicException - route not found`, which reads as a model
  or credentials problem and says nothing about a missing HTTPRoute. Nothing in the
  lab sets this variable; if a pod has it, that is drift from an older policy and the
  agent will fail every prompt until it is removed.
- **The chart's licence path is `licensing.licenseKey`**, and agentgateway wants
  `AGENTGATEWAY_LICENSE_KEY` rather than the generic gloo-mesh `SOLO_LICENSE_KEY`.
- **Do not set `providers.anthropic.apiKey` on the kagent chart** if you pre-create
  `kagent-anthropic` yourself. The chart then tries to own the Secret and Helm
  refuses the whole install with `invalid ownership metadata`. The chart already
  defaults to `apiKeySecretRef: kagent-anthropic`, so creating the Secret is enough.
- **Read HTTPRoute acceptance from `status.parents[].conditions`.** There is no
  top-level `Accepted` condition, so `kubectl wait --for=condition=Accepted` always
  times out on a route that is perfectly healthy.

## Status

**Run end to end on kind, 2026-08-04.** agentgateway `v2026.7.1`, kagent Enterprise
`0.5.3`, Enterprise AgentRegistry `2026.6.1`, arctl `v2026.6.1`, Kyverno `v1.13.4`,
Gateway API `v1.5.1`, Kubernetes `v1.35.0`.

What was actually observed, not inferred:

- Both agents deploy from the catalogue pointing at `/mcp`, and keep it.
  AgentRegistry does not overwrite the literal `MCP_SERVERS_CONFIG`.
- After the verdict, the red BYO agent's pod carries
  `KAGENT_REQUIRE_APPROVAL=restart_deployment,scale_deployment` and the red
  declarative agent's CR carries the matching `requireApproval`. The green agent is
  untouched. Neither agent was rebuilt or republished.
- Both lists come from the register, not the policy. Rewriting `gated` to name only
  `scale_deployment` and re-admitting produced exactly `["scale_deployment"]` on the
  declarative agent and `scale_deployment` on the BYO one.
- `tools: ["*"]` expanded to all five of the server's tools on the declarative agent
  (`list_pods, get_pod_logs, describe_deployment, restart_deployment,
  scale_deployment`) and to `*` on the BYO agent, which its toolsets read as
  gate-everything.
- The red agent reads freely and pauses only where it acts. Asked to restart
  `checkout`, the task comes back `input-required` with an
  `adk_request_confirmation`, and the MCP server's audit log is empty at that moment.
- Approve → the task moves to `completed`, the tool runs, the agent reports
  `ready: 3/3` and goes on to explain the underlying OOM. The audit log gains its
  one entry.
- Reject → `checkout` stays as it was and the audit log stays empty. The call never
  reached the tool server.
- The green agent, given the identical prompt, restarts immediately with no pause.
- Approving over the API works with nothing but `curl`: a Keycloak password-grant
  token, one `message/send` to get the pause, and a second carrying a
  `function_response` part on the same `taskId`/`contextId`.
- The reject path is proven against the tool server, not just the transcript: after
  a reject the audit log is still empty and `checkout` is untouched. After an
  approve it has exactly one entry.
