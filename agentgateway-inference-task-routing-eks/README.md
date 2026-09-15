# Prompt-aware model routing, Part 4: private by default, frontier by exception

One endpoint for everyone in the company. The router says what kind of task a prompt is.
OPA turns the task and the caller's permissions into where it runs and which class of
model answers. Private GPUs are the default. The frontier is an exception: a clearly
generic coding question, from someone permitted to use it, and nothing else. Uncertain
stays private. Evidence that the prompt carries the company's own code keeps it private
whatever the task looked like. A credential in the prompt blocks it. A caller with no
permitted private model gets an error, never a frontier model.

This part layers on [Part 3](../agentgateway-inference-identity-routing-eks/): same
cluster, same single GPU with both open-weight models, same router and OPA. It reorders
the decision. Part 3 decided where a request runs from the identity alone, before the
prompt was read. Here the task comes first.

**Editions.** Everything here is on the OSS agentgateway CRDs: `traffic.jwtAuthentication`
with `preserveToken`, `traffic.extProc`, `traffic.extAuth` with `forwardBody`, all at
`phase: PreRouting`, and `AgentgatewayBackend.spec.policies.ai.modelAliases`. Validated on
upstream agentgateway v1.5.0.

## Why two hops

Inside `PreRouting` the gateway runs extAuth before extProc, so on one gateway OPA would
answer before the router had said what the task is. This flow needs the other order. So
the public gateway authenticates and classifies, and hands every request to a second,
internal gateway where OPA sees the task, the verified identity and the prompt together
and the route acts on OPA's answer. The router is called once. OPA returns both the pool
and the class.

```
client ──▶ model-gateway ────────────────▶ decision-gateway ──────────────▶ backend
           1 verify token (keep it)         3 verify token again            Qwen3-Coder    (private, coding)
           2 router: task label             4 OPA: task + permissions       Mistral        (private, finance / general)
             code_review | code_modification   + data checks → pool, class  Anthropic      (approved-frontier, generic coding)
             generic_coding | finance        5 route on pool and class
             uncertain
```

## The routing table

`opa/routing-data.json`, loaded into OPA as data. Permissions constrain the destinations
the table can select; the task determines the preferred one.

| Task (from the router) | Pool | Class | Model |
|---|---|---|---|
| `code_review` | private | coding | Qwen3-Coder-30B |
| `code_modification` | private | coding | Qwen3-Coder-30B |
| `finance` | private | finance | Mistral-Small-24B |
| `generic_coding` | approved-frontier, if permitted; otherwise private | coding | Claude Sonnet, or Qwen3-Coder |
| `uncertain` | private | general | Mistral-Small-24B |

| User | May use |
|---|---|
| bob | private, approved-frontier |
| alice | private |
| dave | approved-frontier only, so a review from dave is an error |

Rule precedence in `opa/routing.rego`, first match wins: a credential in the prompt blocks;
the company's own code in the prompt, or an internal repository named in `x-source-repo`,
forces private; then the table's preferred pool if permitted; then private if permitted;
then an error. There is no fall-through to the frontier.

## Run it

Needs Part 3 up (its `./scripts/00-check.sh` and, if the GPU node is scaled down, its
`./scripts/gpu.sh up`), plus an Anthropic key in the environment. About ten minutes: the
router restarts twice and the classifier weights are already on its volume.

```bash
export ANTHROPIC_API_KEY=...

./scripts/00-check.sh             # Part 3 is serving
./scripts/01-identity.sh          # tokens for bob, alice, dave, and a forgery; reuses Part 3's signing key
./scripts/02-router.sh            # step 1: the router becomes a task classifier
./scripts/03-opa.sh               # step 2: OPA with the routing table and the data checks
./scripts/04-decision-gateway.sh  # step 3: the decision gateway, backends, policy and route
./scripts/05-classify-gateway.sh  # step 4: the public gateway verifies, classifies, hands on
```

Or `./scripts/quick.sh up`.

## Test it

```bash
source identity/tokens.env
./scripts/06-test-flow.sh         # bob's five prompts and alice's one
./scripts/07-test-controls.sh     # internal code, provenance, a credential, dave, spoofing, bad tokens
./scripts/08-show-decision.sh bob "Review this function for concurrency bugs: ..."
./scripts/classify.sh "Look at this code and tell me if the lock is released on every path."
```

`classify.sh` is the tuning tool: it prints the task the router chose, the decision that
chose it and the similarity scores behind it, for one prompt.

## Files

```
opa/routing.rego                  the decision: block, force private, prefer, fall back, refuse
opa/routing-data.json             who may use which pool; task to pool and class; internal-code markers
yaml/10-router-tasks.yaml         the router as a task classifier: similarity banks, keywords, domains
yaml/20-opa.yaml                  OPA with /config, /policy and /data mounts
yaml/30-decision-gateway.yaml     the second hop, ClusterIP
yaml/40-backends.yaml             Qwen3-Coder, Mistral, Anthropic, with the task labels aliased
yaml/50-decide-policy.yaml.tmpl   verify the token again, ask OPA with the body
yaml/60-decision-route.yaml       four rules on x-model-pool and x-model-class
yaml/70-classify-policy.yaml.tmpl verify and keep the token, run the router
yaml/80-classify-route.yaml       everything to the decision gateway
```

## Teardown

```bash
./scripts/99-restore.sh           # Part 3 back as it was; the models and the cluster are untouched
```
