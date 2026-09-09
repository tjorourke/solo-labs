# Prompt-aware model routing on agentgateway (EKS, real GPUs)

Two open-weight models on two GPUs behind one endpoint, and the gateway decides which
one answers based on what the prompt is about. A finance question goes to Mistral. A
coding question goes to Qwen3-Coder. The client sends `"model": "auto"` and never names
either.

This is part 2 of [vLLM Semantic Router on agentgateway](../vllm-semantic-router-agentgateway/).
Part 1 runs on kind with a vLLM simulator and mock LoRA adapters, and proves the router
can pick an adapter behind a single backend. This one runs on real GPUs in EKS with two
real models, on **Solo Enterprise for agentgateway**, and shows how that decision
becomes a different upstream.

## What this lab is not

It is not a cluster build. It assumes the cluster, gateway and mesh from
[sovereign-ai-uk-eks](../sovereign-ai-uk-eks/). This lab is the Solo install and config
on top: a second model, two backends, one policy, one route, and a kagent agent.

## The mechanism

Gateway API matches routes on **headers**. It has no body matcher. Prompt-aware routing
is therefore two moves:

1. a policy at the `PreRouting` phase lifts a value out of the JSON body into a header
2. the HTTPRoute matches that header and chooses a backend

`phase: PreRouting` is load-bearing. The default is `PostRouting`, which runs after the
route has been selected, so a header set there cannot influence the choice it exists to
influence. Set the phase wrong and every request lands on the default backend with a
200.

## The ladder

The routing table is identical at every rung. Only the source of the decision changes,
which is the point: the HTTPRoute does not know who decided.

| Rung | Who decides | Cost |
|---|---|---|
| 1 | the client, by naming a model | nothing |
| 2 | the gateway, with a CEL heuristic over the prompt | nothing, no new component |
| 3 | the vLLM Semantic Router, classifying by embedding | one more service, several GB of classifier models |

This lab ships rungs 1 and 2 and is wired so rung 3 drops in without touching the
route. Rung 3 uses `traffic.extProc` with `processingOptions.requestBodyMode: Buffered`
and `allowModeOverride: true`, which the Enterprise CRD carries from the 2026.8 line.

## Prerequisites

- The `sovereign-ai-uk-eks` cluster up, with `sovereign-gateway-internal` programmed.
- **Two** GPU nodes. The nodegroup ships at `desiredSize: 0` and part 1 uses one.
- Roughly **$11.70/hr** while both nodes are up. The parent lab's
  `scripts/gpu-backstop.sh` scales the nodegroup to zero at 21:00 UTC nightly and takes
  both models down together.

## Sizing

The NVIDIA device plugin hands out whole GPUs, so each model gets its own node. On a
96 GB card:

| Model | Weights | Both on one card |
|---|---|---|
| Mistral-Small-3.2-24B | 44.7 GB | |
| Qwen3-Coder-30B-A3B bf16 | 61.1 GB | 105.8 GB, does not fit |
| Qwen3-Coder-30B-A3B **FP8** | 31.2 GB | 75.9 GB, fits with ~20 GB for both KV caches |

With a card each, FP8 is a throughput and load-time choice rather than a capacity one:
half the load time, and roughly 60 GB of KV headroom instead of 30.

## One vLLM per model

vLLM is not an operator and ships no CRD. A vLLM process loads **one** model at startup
and serves it, so `vllm` and `vllm-qwen` are two independent Deployments, each with its
own pod, GPU, PVC and Service. The declarative part is the Solo layer: one
`EnterpriseAgentgatewayBackend` per model, one policy, one route.

The exception is LoRA. A single vLLM can serve one base model plus many adapters
(`--enable-lora`, `--lora-modules`, and the client names the adapter in the `model`
field), sharing one GPU allocation. All adapters share a base, so it does not help when
you want Mistral for finance and Qwen-Coder for code.

## Deploy it

All five steps are wrapped as `scripts/quick.sh up`.

### 1. Second GPU node

Move `maxSize` with `desiredSize`, or the second node is capped and never arrives.

```bash
aws eks update-nodegroup-config --region eu-west-2 --cluster-name uk-sovereign-ai \
  --nodegroup-name gpu-od --scaling-config minSize=0,maxSize=2,desiredSize=2

kubectl get nodes -l role=gpu -o custom-columns=\
'NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,GPU:.status.allocatable.nvidia\.com/gpu'
```

A `g7e.2xlarge` in eu-west-2a registered and advertised `nvidia.com/gpu` in 75 seconds.
Check the nodegroup **Health** field as well as the node list.

### 2. The coding model

```bash
kubectl apply -f yaml/00-qwen-model.yaml
kubectl rollout status deploy/vllm-qwen -n models --timeout=1500s
```

Weights are fetched by an init container so the volume binds on the node that will run
the model. First run pulls about 31 GB; the whole rollout took about 12 minutes.

The deployment sets `VLLM_USE_DEEP_GEMM=0` and `VLLM_MOE_USE_DEEP_GEMM=0`. Both are
required for this model on this card, and vLLM selects a working FP8 MoE backend with
them in place.

### 3. A backend per model

```bash
kubectl apply -f yaml/10-backends.yaml
```

Only Qwen is defined; the Mistral backend already exists in the parent lab and is
reused. `model` on the backend must match vLLM's `--served-model-name` exactly, and
`ai.provider` stays singular so prompt guards keep binding.

### 4. Policy and route

```bash
kubectl apply -f yaml/20-routing-policy.yaml
kubectl apply -f yaml/30-httproute.yaml

kubectl get enterpriseagentgatewaybackends,enterpriseagentgatewaypolicies -n agentgateway-system
```

Both should report `ACCEPTED` and the policy `ATTACHED`. Not cosmetic: a policy that
fails to attach leaves the header unset, no rule matches, and every request serves the
default model with a 200.

### 5. kagent

```bash
kubectl apply -f yaml/40-kagent-modelconfig.yaml
kubectl apply -f yaml/50-kagent-agent.yaml \
  --as=system:serviceaccount:kagent:kagent-controller
```

The `ModelConfig` requests `auto`, which is what makes the agent a client of the
routing rather than of a model. The agent is declarative, so there is no container to
build. On the sovereign cluster, Agent creation is reserved to the kagent control
plane, hence the `--as`; elsewhere apply it normally.

Three settings exist for this cluster and can be dropped elsewhere:
`a2aConfig.skills` (an agent card with no skills list is rejected by the runtime at
startup), `deployment.imageRegistry: ghcr.io` (the cluster's registry allowlist does not
carry the kagent default), and an explicit `deployment.resources` block (it requires CPU
and memory limits on every container).

## How the classifier behaves

`yaml/20-routing-policy.yaml` does three things deliberately:

- **An explicitly named model wins.** Only `auto`, or a request with no `model` field,
  is classified.
- **It reads the last message, not the first.** `messages[0]` is usually a system
  prompt, and in a multi-turn chat the opening user turn stops being what the request is
  about after turn two.
- **It matches both shapes of `content`.** The OpenAI chat API allows `content` to be a
  plain string or a list of typed parts. curl and most SDKs send a string; ADK and
  LiteLLM-based agents send `[{"type":"text","text":"..."}]`. The `||` covers both, so
  agent traffic classifies the same way client traffic does.

## Testing it

```bash
SOVEREIGN_AWS_PROFILE=<your sandbox SSO profile> ./scripts/test.sh
```

Seven requests to one endpoint. Six send `"model": "auto"`; the seventh names a model to
prove classification is bypassed when a client has already chosen.

```
ok  FIN str    What is IFRS 9 stage 2 impairment?                     -> mistral-small-3.2-24b
ok  FIN parts  Explain the difference between CVA and DVA...          -> mistral-small-3.2-24b
ok  FIN str    Summarise our Q3 results for the board.                -> mistral-small-3.2-24b
ok  COD str    Write a Python function to reverse a linked list.      -> qwen3-coder-30b
ok  COD parts  Refactor this to remove the nested loop...             -> qwen3-coder-30b
ok  COD parts  Debug why my SQL query returns duplicates.             -> qwen3-coder-30b
ok  PINNED     (client names qwen3-coder-30b)                         -> qwen3-coder-30b

all 7 cases routed as expected
```

## Seeing the model choice from the agent

Submit one finance prompt and one coding prompt over A2A, then read the gateway log.

```bash
POD=$(kubectl get pods -n kagent -l kagent=routing-demo -o jsonpath='{.items[0].metadata.name}')

kubectl exec -i -n kagent "$POD" -- python3 - <<'PY'
import json, urllib.request, uuid
def ask(t):
    p = {"jsonrpc":"2.0","id":str(uuid.uuid4()),"method":"message/send",
         "params":{"message":{"role":"user","messageId":str(uuid.uuid4()),
                              "parts":[{"kind":"text","text":t}]}}}
    urllib.request.urlopen(urllib.request.Request("http://localhost:8080/",
        data=json.dumps(p).encode(),
        headers={"Content-Type":"application/json"}), timeout=180).read()
ask("Explain the difference between CVA and DVA in derivative pricing.")
ask("Refactor this Python function to remove the nested loop and add a unit test.")
PY

kubectl logs -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name=sovereign-gateway-internal --tail=2 \
  | tr ' ' '\n' | grep -E '^(endpoint|gen_ai.response.model|gen_ai.usage.output_tokens)=' | paste - - -
```

```
endpoint=vllm.models.svc.cluster.local:8000       gen_ai.response.model=mistral-small-3.2-24b  gen_ai.usage.output_tokens=411
endpoint=vllm-qwen.models.svc.cluster.local:8000  gen_ai.response.model=qwen3-coder-30b        gen_ai.usage.output_tokens=396
```

One agent, one endpoint, two prompts, two models, and the agent named neither.
`endpoint=` is the field that settles it: it is the upstream the gateway actually
dialled, and unlike a model name in a response body it cannot come from a backend
pinning a value. The same records carry per-model token counts, which is what a
cost-per-team view is built from.

## Teardown

```bash
SOVEREIGN_AWS_PROFILE=<profile> ./scripts/quick.sh teardown
```

Removes this lab's objects and scales back to **one** GPU node, not zero, because part
1's Mistral is on the other card. The `qwen-weights` PVC is left in place on purpose: it
holds 31 GB that costs another download to replace.
