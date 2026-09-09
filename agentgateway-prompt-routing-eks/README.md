# Prompt-aware model routing on agentgateway (EKS, real GPUs)

Two open-weight models on two GPUs behind one endpoint, with the gateway choosing which
one answers. A finance question goes to Mistral, a coding question goes to Qwen3-Coder,
and the caller does not have to know which is which.

Part 2 of [vLLM Semantic Router on agentgateway](../vllm-semantic-router-agentgateway/).
Part 1 runs on kind with a simulator and mock LoRA adapters and shows a router picking
an adapter behind one backend. This runs on real GPUs with two real models and shows the decision selecting a
different upstream.

**Editions.** Nothing in the routing needs Enterprise. Every field used here is on the
OSS agentgateway CRDs (`spec.traffic.phase` with `PreRouting`,
`spec.traffic.transformation`, `spec.traffic.extProc.processingOptions`, and
`spec.ai.provider`), and no Enterprise-only field appears in it. The lab was built and
validated on Solo Enterprise because that is what the parent cluster runs, and the
console and cost views are Enterprise. `yaml-oss/` holds the converted manifests, not
yet run live, so the Versions footer records the Enterprise build only.

## The scenario

A bank runs its own GPUs. Finance and risk staff ask about accounting treatment,
capital and reporting. Engineers ask about code, Kubernetes and deployments that will
not start. Both go through the same internal assistant. Two questions run through the
lab as the example pair:

| Question | What it is | Wants |
|---|---|---|
| "What is IFRS 9 stage 2 impairment?" | IFRS 9 is the accounting standard for financial instruments. Stage 2 is where a loan's credit risk has risen enough that the bank provisions for losses expected over its whole remaining life rather than the next year. | the general model |
| "Why is my pod stuck in CrashLoopBackOff?" | A Kubernetes workload that starts, fails and is restarted repeatedly. | the code model |

Both cards are paid for whether or not the traffic uses them well. The second GPU only
returns anything if requests reach the model that suits them, and nothing in the URL,
the method or the caller's identity says which that is. The only thing that does is the
prompt.

## Three ways a request reaches a model

The routing table is identical in all three. Only the source of the decision changes.

| Option | Who decides | Cost |
|---|---|---|
| Client-declared | the client names a model | nothing |
| Keyword match | the gateway matches words in the prompt | nothing, no new component |
| Semantic | a classifier reads the meaning of the prompt | one more service, several GB of model weights |

All three are deployed here. Three kagent agents cover both patterns:

| Agent | ModelConfig | Who decides |
|---|---|---|
| `finance-analyst` | `model-mistral` | the caller, by picking the agent |
| `coding-assistant` | `model-qwen` | the caller, by picking the agent |
| `routing-demo` | `route-auto`, asks for `auto` | the gateway, from the prompt |

## Prerequisites

- A Kubernetes cluster with agentgateway installed and the Gateway API **experimental**
  channel applied. Written and run on EKS in eu-west-2; nothing is EKS-specific beyond
  the nodegroup commands.
- **Two** GPU nodes, one per model, each with enough VRAM for its model.

## The mechanism

Gateway API matches routes on **headers** and has no body matcher. So the decision
becomes a header before the route is chosen:

1. a policy at the `PreRouting` phase puts the decision in a header
2. the HTTPRoute matches that header and picks a backend

`phase: PreRouting` is the part to get right. The default is `PostRouting`, which runs
after the route has been selected, so a header set there changes nothing. Nothing
errors, and every request lands on the default backend.

## Sizing

The NVIDIA device plugin hands out whole GPUs, so each model gets its own node. On a
96 GB card:

| Model | Weights | Both on one card |
|---|---|---|
| Mistral-Small-3.2-24B | 44.7 GB | |
| Qwen3-Coder-30B-A3B bf16 | 61.1 GB | 105.8 GB, does not fit |
| Qwen3-Coder-30B-A3B **FP8** | 31.2 GB | 75.9 GB, ~20 GB left for both KV caches |

With a card each, FP8 is a throughput and load-time choice: half the load time and
roughly 60 GB of KV headroom instead of 30.

vLLM is not an operator and ships no CRD. One process serves one model, so `vllm` and
`vllm-qwen` are two independent Deployments. The gateway config is the declarative part:
one `AgentgatewayBackend` per model, one policy, one route. Those are the OSS kinds; the
Enterprise set is the same shape with an `Enterprise` prefix.

## Deploy it

Six steps on an EKS cluster that already has agentgateway, all wrapped as
`scripts/quick.sh up`.

**What the gateway install has to include.** This lab does not install agentgateway;
your cluster build does. The **Gateway API experimental channel** is required, because
ExtProc rides on it and the standard channel does not carry it. Nothing else needs
enabling: AI backends are part of the gateway, and `inferenceExtension.enabled` is for
`InferencePool` routing across replicas of one model, which this lab does not use. On
OSS that is `experimental-install.yaml` plus the `agentgateway-crds` and `agentgateway`
charts; on Enterprise the same with the `enterprise-` charts and a licence key.

```bash
# 1. two GPU nodes, one per model. The nodegroup ships at 0 and the nightly backstop
#    returns it there, so assume you start from zero. maxSize must move with desiredSize,
#    because the cluster build gpu.sh hardcodes maxSize=1 and the second node would be capped.
aws eks update-nodegroup-config --region eu-west-2 --cluster-name <your-cluster>   --nodegroup-name gpu-od --scaling-config minSize=0,maxSize=2,desiredSize=2

# 2. the second model. Mistral already runs from the cluster build on the first card.
#    First run pulls ~31 GB; the rollout took about 12 minutes.
kubectl apply -f yaml/01-qwen-model.yaml
kubectl rollout status deploy/vllm-qwen -n models --timeout=1500s

# 3. a backend per model (only Qwen; Mistral's exists in the cluster build)
kubectl apply -f yaml/10-backends.yaml

# 4. the policy and the route
kubectl apply -f yaml/20-routing-policy.yaml -f yaml/30-httproute.yaml
kubectl get enterpriseagentgatewaybackends,enterpriseagentgatewaypolicies -n agentgateway-system

# 5. the agents: one asking for auto, two naming a model
kubectl apply -f yaml/40-kagent-modelconfig.yaml
kubectl apply -f yaml/50-kagent-agent.yaml -f yaml/60-kagent-specialist-agents.yaml \
  --as=system:serviceaccount:kagent:kagent-controller

# 6. the semantic router (optional). First start downloads the classifier weights.
helm upgrade --install semantic-router \
  oci://ghcr.io/vllm-project/charts/semantic-router \
  -n agentgateway-system --version v0.0.0-latest \
  -f yaml/70-semantic-router-values.yaml
kubectl rollout status deploy/semantic-router -n agentgateway-system --timeout=1800s
kubectl apply -f yaml/80-semantic-router-extproc.yaml -f yaml/81-httproute-vsr.yaml
```

Two vLLM flags on the Qwen Deployment are not optional: `VLLM_USE_DEEP_GEMM=0` with
`VLLM_MOE_USE_DEEP_GEMM=0`, and `--enable-auto-tool-choice --tool-call-parser=qwen3_coder`.
Check the backends report `ACCEPTED` and the policy `ATTACHED`; a policy that fails to
attach leaves the header unset and every request serves the default model with a 200.

`yaml/70` maps the classifier's built-in MMLU-Pro domains onto the two models, so there
is no training to do for this split: `economics` and `business` to the general model,
`computer science` and `engineering` to the code model, everything else and anything
below the confidence threshold to the default.

### Switching between the classifiers

```bash
# semantic
kubectl apply -f yaml/80-semantic-router-extproc.yaml -f yaml/81-httproute-vsr.yaml
# keyword
kubectl apply -f yaml/20-routing-policy.yaml -f yaml/30-httproute.yaml
```

## Testing

```bash
AWS_PROFILE=<sandbox SSO profile> ./scripts/test.sh              # 7 cases, current config
AWS_PROFILE=<sandbox SSO profile> ./scripts/test-classifiers.sh  # keyword vs semantic
```

`test-classifiers.sh` switches the policy twice and runs the same nine prompts through
both:

```
PROMPT                                            SHOULD    KEYWORD    SEMANTIC
What is IFRS 9 stage 2 impairment?                finance   ok         ok
Explain the difference between CVA and DVA        finance   ok         ok
What is our Python licensing spend this quarter?  finance   X coding   X coding
Model the credit risk function for our loan book  finance   X coding   ok
Write a Python function that reverses a list      coding    ok         ok
Why is my pod stuck in CrashLoopBackOff?          coding    X finance  ok
Make this run faster without the inner loop       coding    X finance  ok
Write a Golang handler for an S3 upload           coding    X finance  ok
How do I set a Terraform provider version?        coding    X finance  ok

keyword classifier:  3/9 correct
semantic classifier: 8/9 correct
```

Five of the six keyword failures are misses that could each be fixed by adding a word.
The sixth cannot: "Model the credit risk function for our loan book" is a finance
question that reached the code model because it contains `function`. Every keyword
added to catch a miss widens the surface for a false positive.

Both get "What is our Python licensing spend this quarter?" wrong. That sentence is
genuinely ambiguous, and it is what the confidence threshold and a default model are
for.

### Seeing which model answered

The gateway access log is the authoritative view, because `endpoint=` is the upstream
it actually dialled and cannot be faked by a backend pinning a name:

```bash
kubectl logs -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name=model-gateway --tail=2 \
  | tr ' ' '\n' | grep -E '^(endpoint|gen_ai.response.model|gen_ai.usage.output_tokens)=' | paste - - -
```

```
endpoint=vllm.models.svc.cluster.local:8000       gen_ai.response.model=mistral-small-3.2-24b  411
endpoint=vllm-qwen.models.svc.cluster.local:8000  gen_ai.response.model=qwen3-coder-30b        396
```

The kagent trace view shows `auto` on the agent spans, because that is all the agent
asked for, and the per-span `LLM` field is empty. The served model reaches the rollup
tables behind the cost views, not the individual span.

### From the kagent UI

In the kagent console, pick `routing-demo` for the classified path or `finance-analyst`
and `coding-assistant` for the declared one, and send the prompts above. The gateway log
command in the previous section prints the model that served each request as you type.


## Things that will catch you

| | |
|---|---|
| **DeepGEMM crash-loops Qwen FP8** | vLLM 0.27.1 auto-selects the DEEPGEMM FP8 MoE backend on the RTX PRO 6000 and dies at engine init with `Assertion error (layout.hpp:60): Unknown SF transformation`. `VLLM_USE_DEEP_GEMM=0` and `VLLM_MOE_USE_DEEP_GEMM=0` fix it. |
| **Qwen needs a tool parser** | kagent sends `tools` on every request and vLLM defaults `tool_choice` to `auto`, so without `--enable-auto-tool-choice --tool-call-parser=qwen3_coder` it 400s on every agent request while the routing still looks fine. |
| **The transformation runs before the ExtProc** | In one `PreRouting` policy the transformation is evaluated first, and the processor's body rewrite lands after the backend pinned its model. Both in one policy gives a request whose route came from the regex and whose body came from the router, and a 400 when they disagree. The semantic policy therefore has no transformation. |
| **The header is `x-selected-model`** | `x-vsr-selected-model` is a *response* header with the same value. Matching it gives a route that never matches, with no error anywhere. |
| **Read both content shapes** | `content` can be a string or a list of typed parts. curl sends a string, ADK and LiteLLM agents send parts. Matching only the string shape silently sends all agent traffic to the default model. |
| **The vSR chart PVC** | defaults to a `standard` StorageClass that does not exist on EKS, so the pod reports an unbound claim rather than a config error. `yaml/70` sets `gp3`. |
| **kagent admission here** | Agent creation is reserved to the kagent control plane, hence the `--as`. The agents also need `a2aConfig.skills` (a card with no skills list is rejected at startup), `imageRegistry: ghcr.io` and an explicit `resources` block. Drop the last three on a cluster without those policies. |

## Teardown

```bash
AWS_PROFILE=<profile> ./scripts/quick.sh teardown
```

Removes this lab's objects and scales back to **one** GPU node, not zero, because part
1's Mistral is on the other card. The `qwen-weights` PVC is left in place: it holds
31 GB that costs another download to replace.
