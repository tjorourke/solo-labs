# Prompt-aware model routing, Part 3: identity decides frontier or open-weight

One endpoint, one request shape, two decisions before the route is chosen. Who is asking
decides where the request may run: on the open-weight models on your own GPU, or at a
frontier provider. What they are asking decides which class of model answers it. The
client sends `"model": "auto"` and a bearer token, and never names a provider, a model or
a credential.

[Part 1](../agentgateway-inference-model-routing-eks/) routes on the prompt's subject and
[Part 2](../agentgateway-inference-signal-routing-eks/) adds its complexity, both across
two open-weight models on two GPUs. This part keeps those two models, puts them on one
GPU, and adds two frontier providers and an identity layer in front of all four.

**Editions.** Everything here is on the OSS agentgateway CRDs: `traffic.jwtAuthentication`,
`traffic.extAuth` with `grpc`, `traffic.extProc` with `processingOptions`, all at
`phase: PreRouting`, and `AgentgatewayBackend.spec.policies.ai.modelAliases`. Validated
on upstream agentgateway v1.5.0.

## The scenario

A company gives its people one internal AI endpoint. Some of its work is classified
restricted and may not leave the company's own infrastructure. The rest may use a frontier
provider, and which one is a matter of contract: Alice's team is contracted to OpenAI,
Bob's to Anthropic. Carol works on restricted data. Nobody may change any of that by
editing a request. And not every prompt deserves the same model: a definition can go to a
general model, a diagnosis should go to the code model, wherever it runs.

| | basic prompt | hard prompt |
|---|---|---|
| **alice**, internal, contracted to OpenAI | gpt-5.4-mini | gpt-5.4 |
| **bob**, internal, contracted to Anthropic | claude-sonnet-5 | claude-opus-5 |
| **carol**, restricted | Mistral-Small-24B on the GPU | Qwen3-Coder-30B on the GPU |

Same prompt, different identity: different place. Same identity, different prompt:
different model. The two prompts are the pair from Part 2, both about optimistic
concurrency control, one asking for an explanation and one for a diagnosis.

## Who decides what

| Component | Decides | Reads | Never sees |
|---|---|---|---|
| agentgateway | that the token is valid, and who `sub` is | the JWT | |
| OPA | where this identity's requests may run: `self-hosted`, `openai` or `anthropic` | the verified `sub`, the entitlement data | the prompt, any provider key |
| vLLM Semantic Router | which class of model the prompt needs: `general` or `code` | the prompt | who is asking, where it will run |
| HTTPRoute | which backend gets the request | `x-routing-target`, and for the GPU also `x-selected-model` | |
| AgentgatewayBackend | what `general` and `code` mean for the model it fronts | its own `modelAliases` | |

All of it happens in one `AgentgatewayPolicy` at `PreRouting`, in the order the gateway
runs the phase: JWT, then extAuth, then extProc, then route selection.

## One GPU, two models

Each model runs on its own g7e.2xlarge, as Part 1 does. The NVIDIA device plugin hands
out whole cards, so each node advertises `nvidia.com/gpu: 1` and the scheduler puts one
vLLM pod on each. `scripts/02-models.sh` applies Part 1's own model manifests with one
number changed, the context window: 131072 for Mistral, 262144 for Qwen.

Time-slicing fits both models onto one card and halves what each can do. It shares
compute by turn and does nothing about memory, so the two divide the 96 GB with
`--gpu-memory-utilization`, the KV cache shrinks with the share, and the context window
has to shrink to what the cache holds. An agent client runs into that first: Claude Code
sends its instructions and its tools on every turn, a little over 32k tokens before
anyone has typed anything. Two cards cost about $11.70/hr against $5.85 for one.

## Run it

Needs `aws`, `eksctl`, `kubectl`, `helm`, `openssl`, `python3`, `curl`, an AWS identity,
the Part 1 lab checked out next to this one, and two frontier keys in the environment.
On the Part 1 cluster with the weights already on their volumes, about twenty minutes. On
a fresh cluster, about an hour and a half, most of it the 76 GB weight pull.

```bash
export OPENAI_API_KEY=...
export ANTHROPIC_API_KEY=...

./scripts/00-check.sh            # tools, AWS identity, keys
./scripts/01-cluster.sh          # the cluster (Part 1's, or a two-GPU build of it), agentgateway v1.5.0, device plugin
./scripts/02-models.sh           # Part 1's two models, on the one card
./scripts/03-identity.sh         # a signing key, a JWKS, tokens for alice, bob, carol and two bad ones
./scripts/04-opa.sh              # the gateway, then OPA with its policy and entitlement data
./scripts/05-semantic-router.sh  # vLLM Semantic Router, pinned chart and image
./scripts/06-backends.sh         # two GPU backends, two frontier backends, two Secrets
./scripts/07-routing.sh          # the one policy and the four-rule route
```

Or `./scripts/quick.sh up`, which runs the eight in order.

**Do not ship the ConfigMap.** It is the lab's entitlement source because it is the
smallest thing that proves the point. Kubernetes caps a ConfigMap at 1 MiB of data, which
at about 90 bytes per user the way `opa/entitlements.json` is written is somewhere around
eleven thousand users, with nothing left for groups, several entitlements per person or an
audit trail. Every change is a full rewrite and an OPA restart, and the data is readable by
anything with access to the namespace. A company-wide table belongs behind OPA's bundle
API or in a data source OPA queries at decision time; the gateway and the router do not
change.

There is no Keycloak. The lab is about routing, and all the gateway needs from an identity
provider is a JWKS to check signatures against, so `03-identity.sh` generates an RSA key
per clone, writes its public half as `identity/jwks.json`, and mints RS256 tokens. A real
IdP replaces the inline JWKS with `jwks.remote`. Nothing else changes.

## Test it

```bash
source identity/tokens.env
./scripts/09-test-matrix.sh      # the seven cases: three users, the two prompts, one finance question
./scripts/10-test-negative.sh    # thirteen refusals and spoofing attempts
./scripts/08-show-decisions.sh carol "Two writers report successful updates ... propose a safe write protocol."
```

The matrix reads three things off every response: `x-routing-target` is OPA's decision,
`x-vsr-selected-model` is the router's, and the `model` field in the body is the serving
model's own statement of which model answered, which nothing on the gateway can fake.

## Change one attribute

```bash
./scripts/11-move-user.sh alice restricted   # alice's work is now restricted
./scripts/04-opa.sh                          # back to what opa/entitlements.json says
```

The script edits one field in the ConfigMap, restarts OPA so it reloads, and sends the
hard prompt as alice. It comes back from Qwen3-Coder on the GPU instead of gpt-5.4. The
client, the router, the route and all four backends are untouched.

## What a client can and cannot name

The body's `model` field is not free text. `auto` is classified. `general` or `code` is
honoured as the caller's choice of class, wherever OPA said the request may run. Any other
value, a real model name included, is refused by the router with a 400 before any backend
is called. The internal headers are removed by OPA before it writes its own, and the router
overwrites its own on every request, so sending them from the client changes nothing.
`10-test-negative.sh` proves each of those, and the one that matters most: a restricted
user asking for a frontier provider by header still lands on the GPU.

## Fail closed

Both policy components are `FailClosed`. With OPA down the gateway answers 403. With the
router down it answers 500. Neither case reaches a backend, and neither falls back to a
default.

## Files

```
eks/cluster.yaml                    Part 1's cluster config with the gpu nodegroup at one node
identity/                           generated per clone: signing key, JWKS, tokens (gitignored)
opa/routing.rego                    restricted -> self-hosted, otherwise the contracted provider; or 403
opa/entitlements.json
yaml/01-device-plugin-values.yaml   NVIDIA device plugin, whole cards, one model each
yaml/10-selfhosted-backends.yaml    Part 1's two vLLM backends plus one alias each
yaml/20-opa.yaml                    OPA with /config, /policy and /data mounts
yaml/40-semantic-router-values.yaml the router: two logical models, Part 2's signals and decisions
yaml/60-openai-backend.yaml         general -> gpt-5.4-mini, code -> gpt-5.4
yaml/61-anthropic-backend.yaml      general -> claude-sonnet-5, code -> claude-opus-5
yaml/70-policy.yaml.tmpl            jwtAuthentication + extAuth + extProc, one PreRouting policy
yaml/80-httproute.yaml              four rules on x-routing-target and, for the GPU, x-selected-model
```

## Teardown

```bash
./scripts/gpu.sh down              # stop the GPU meter; the weights stay on their volumes
./scripts/99-restore.sh            # put Part 1's routing back, remove this part's objects
./scripts/quick.sh teardown        # both of the above, or a full cluster delete if this lab built it
```
