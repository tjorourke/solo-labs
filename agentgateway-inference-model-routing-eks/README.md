# Prompt-aware model routing, Part 1: two models across two GPUs

Two open-weight models on two GPUs behind one endpoint, with the gateway routing each
request to the model that suits it: from an explicit client choice, from its own routing
logic, or from a decision made by vLLM Semantic Router. A finance question goes to
Mistral, a coding question goes to Qwen3-Coder, and the caller does not have to know
which is which.

Standalone. It builds its own EKS cluster, its own GPU nodes and its own gateway, and
shares nothing with any other lab. If you want the same routing on kind with a simulator
instead of real cards, that is
[vLLM Semantic Router on agentgateway](../vllm-semantic-router-agentgateway/).

**Editions.** Nothing in the routing needs Enterprise. Every field used here is on the
OSS agentgateway CRDs (`spec.traffic.phase` with `PreRouting`,
`spec.traffic.transformation`, `spec.traffic.extProc.processingOptions`, and
`spec.ai.provider`), so the scripts run the OSS manifests in `yaml-oss/` and the lab was
validated end to end on upstream agentgateway v1.3.0-alpha.1, and separately on Solo
Enterprise. `yaml/` holds the Enterprise set: the same files with the group and kind
swapped, plus `extProc.failureMode: FailOpen`, the one field here that OSS does not
have.

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

The backend mapping stays the same in all three. Semantic mode replaces the policy
and changes the HTTPRoute's matched header from `x-model` to `x-selected-model`.

| Option | Who decides | Cost |
|---|---|---|
| Client-declared | the client names a model | nothing |
| Keyword match | the gateway matches words in the prompt | nothing, no new component |
| Semantic | vLLM Semantic Router classifies the prompt and the gateway acts on it | one more service, several GB of model weights |

All three are deployed here. Three kagent agents cover both patterns:

| Agent | ModelConfig | Who decides |
|---|---|---|
| `finance-analyst` | `model-mistral` | the caller, by picking the agent |
| `coding-assistant` | `model-qwen` | the caller, by picking the agent |
| `routing-demo` | `route-auto`, asks for `auto` | the gateway, from the prompt |

## Prerequisites

- An AWS account, `eksctl`, `kubectl`, `helm` and the AWS CLI. Nothing else: the lab
  builds its own cluster.
- Quota for two `g7e.2xlarge` in one AZ. London capacity moves hour to hour, so hold
  them with an On-Demand Capacity Reservation before a rehearsal rather than hoping:

  ```bash
  aws ec2 create-capacity-reservation --instance-type g7e.2xlarge \
    --instance-platform Linux/UNIX --availability-zone eu-west-2a --instance-count 2 \
    --instance-match-criteria open --end-date-type limited --end-date <when you finish>
  ```

  `instance-match-criteria=open` means the nodegroup consumes it with no extra config.
  Always set an end date: a reservation bills the full hourly rate with nothing in it.
- About **$11.70/hr** while both GPUs are up, and a few dollars a day for the rest.


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

One command builds everything from an empty AWS account:

```bash
export AWS_PROFILE=<your-profile>
./scripts/quick.sh up
```

That runs six steps, each also runnable on its own:

| Step | What it does | Time |
|---|---|---|
| `eksctl create cluster -f eks/cluster.yaml` | EKS 1.34, a platform nodegroup and two `g7e.2xlarge` in one AZ | ~20 min |
| `scripts/01-gateway.sh` | a default StorageClass, the Gateway API experimental channel, then OSS agentgateway | ~2 min |
| `scripts/02-models.sh` | both vLLM deployments; first run pulls ~76 GB of weights | ~30 min |
| `scripts/03-routing.sh` | gateway, a backend per model, the PreRouting policy, the route | ~1 min |
| `scripts/04-kagent.sh` | kagent and the three agents | ~5 min |
| `scripts/05-semantic-router.sh` | vSR and the policy that hands it the decision | ~5 min |

**The experimental Gateway API channel is required.** ExtProc rides on it and the
standard channel does not carry it. `01-gateway.sh` applies
`experimental-install.yaml` and sets `KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true`
on the controller; with only one of those the semantic router step reports the policy
Accepted and nothing happens.

Nothing else needs enabling. AI backends are part of the gateway, and
`inferenceExtension.enabled` is for `InferencePool` routing across replicas of one
model, which this lab does not use.

### Stopping the meter

The GPUs are the cost, about $11.70/hr for the pair. Everything else idles cheaply.

```bash
./scripts/gpu.sh down     # end of session; weights stay on their volumes
./scripts/gpu.sh up       # back in a few minutes, no re-download
./scripts/quick.sh teardown   # delete the cluster entirely
```

### Enterprise instead of OSS

The manifests in `yaml-oss/` are the OSS CRDs and are what the scripts apply. `yaml/`
holds the Enterprise set: same shapes with an `Enterprise` prefix on the kinds and
`gatewayClassName: enterprise-agentgateway`. One field differs, and only Enterprise has
it: `extProc.failureMode`, which the OSS CRD rejects outright.

## Testing

`classify.sh` is the cheap one. It asks the semantic router to classify the nine prompts
through its own API, so it needs no GPU nodes and costs nothing, and it proves the
classifier plus the domain-to-model mapping in `yaml/70`:

```bash
./scripts/classify.sh
```

```
PROMPT                                               SHOULD   CHOSE                    DOMAIN            CONF
What is IFRS 9 stage 2 impairment?                   finance  ok   mistral-small-3.2-24b business          0.855
Model the credit risk function for our loan book.    finance  ok   mistral-small-3.2-24b economics         0.993
Why is my pod stuck in CrashLoopBackOff?             coding   ok   qwen3-coder-30b     computer science  1.000
...
semantic classifier: 9/9 correct
```

It does not prove the path: the ExtProc call at PreRouting, the `x-selected-model`
header, the route match and the backend rewrite. That needs both models serving:

```bash
./scripts/test-classifiers.sh          # uses the current kubectl context
KUBE_CONTEXT=my-ctx ./scripts/test-classifiers.sh
AWS_PROFILE=... EKS_CLUSTER=my-cluster ./scripts/test-classifiers.sh
```

`test-classifiers.sh` switches the policy twice and runs the same nine prompts through
both:

```
PROMPT                                            SHOULD    KEYWORD    SEMANTIC
What is IFRS 9 stage 2 impairment?                finance   ok         ok
Explain the difference between CVA and DVA        finance   ok         ok
What capital must we hold against a stage 3 loan? finance   ok         ok
Model the credit risk function for our loan book  finance   X coding   ok
Write a Python function that reverses a list      coding    ok         ok
Why is my pod stuck in CrashLoopBackOff?          coding    X finance  ok
Make this run faster without the inner loop       coding    X finance  ok
Write a Golang handler for an S3 upload           coding    X finance  ok
How do I set a Terraform provider version?        coding    X finance  ok

keyword classifier:  4/9 correct
semantic classifier: 9/9 correct
```

Keyword matching fails in two directions. It misses: four coding questions went to the
general model because none used a listed word. Adding `kubernetes`, `pod`, `golang`,
`terraform` and `loop` was measured and takes it from four correct to seven. And it
fires when it should not: "Model the credit risk function for our loan book" is a
finance question that went to the code model because it contains `function`. No word
added fixes that, and each one added makes another false positive more likely.

The semantic router runs its domain classifier, a small fine-tuned BERT-family model
based on mmBERT, over the whole prompt, so an unknown term like CrashLoopBackOff still
classifies from its context, one misleading word does not carry the sentence, and a
low-confidence prediction falls to the default model instead of guessing. It needs no
training for this split: `economics` and `business` map to the general model,
`computer science` and `engineering` to the code model.

Nine prompts is a demonstration, not a benchmark, and the lesson is not that keywords
are bad. Keyword rules are a fine signal, and vSR can take them as one input among
others. What does not hold up is making them the whole classifier.

vSR itself does more than this. It can combine signals such as domain, complexity and
privacy, apply routing policy, narrow the candidate models and choose the inference path
from there. The lab uses domain classification only, so the mechanics stay visible.


### Seeing which model answered

The script reads the model out of each response body. The gateway access log is stronger
evidence, because `endpoint=` is the upstream it actually dialled. Read it off the run
you just did:

```bash
kubectl logs -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name=model-gateway --tail=9 \
  | grep -oE 'endpoint=[^ ]+|gen_ai.response.model=[^ ]+' | paste - -
```

```
endpoint=vllm.models.svc.cluster.local:8000        gen_ai.response.model=mistral-small-3.2-24b
endpoint=vllm.models.svc.cluster.local:8000        gen_ai.response.model=mistral-small-3.2-24b
endpoint=vllm.models.svc.cluster.local:8000        gen_ai.response.model=mistral-small-3.2-24b
endpoint=vllm.models.svc.cluster.local:8000        gen_ai.response.model=mistral-small-3.2-24b
endpoint=vllm-qwen.models.svc.cluster.local:8000   gen_ai.response.model=qwen3-coder-30b
endpoint=vllm-qwen.models.svc.cluster.local:8000   gen_ai.response.model=qwen3-coder-30b
endpoint=vllm-qwen.models.svc.cluster.local:8000   gen_ai.response.model=qwen3-coder-30b
endpoint=vllm-qwen.models.svc.cluster.local:8000   gen_ai.response.model=qwen3-coder-30b
endpoint=vllm-qwen.models.svc.cluster.local:8000   gen_ai.response.model=qwen3-coder-30b
```

Four to the general model and five to the code model, from nine requests that all named
`auto`. The same records carry input and output token counts, which is what a
cost-per-model view is built from. Add `-f` to follow it live while typing in the
console.

### From the kagent UI

In the kagent console, pick `routing-demo` for the classified path or `finance-analyst`
and `coding-assistant` for the declared one, and send the prompts above. The gateway log
command in the previous section prints the model that served each request as you type.

### Measuring latency

The [page's timing section](https://www.mastertheagent.com/solo/agentgateway-inference-model-routing-eks/#timing)
compares explicit, keyword and semantic routing with `scripts/measure-routing.py`.
Both models and vSR must be ready. Run from this directory, with kubectl pointed at
the lab cluster:

```bash
kubectl apply -f yaml-oss/20-routing-policy.yaml -f yaml-oss/30-httproute.yaml
kubectl -n models exec -i deploy/vllm -c vllm -- \
  python3 - explicit --samples 10 < scripts/measure-routing.py
kubectl -n models exec -i deploy/vllm -c vllm -- \
  python3 - keyword --samples 10 < scripts/measure-routing.py

kubectl apply -f yaml-oss/80-semantic-router-extproc.yaml -f yaml-oss/81-httproute-vsr.yaml
kubectl -n models exec -i deploy/vllm -c vllm -- \
  python3 - semantic --samples 10 < scripts/measure-routing.py
```

The script does not change or inspect the policy. Each run warms up twice per prompt,
then measures ten sequential streaming requests per prompt with temperature 0 and a
64-token output limit. It reports median time to first text and total time, plus raw
request IDs, response models and token counts when supplied. Check the policy and
route and verify upstream endpoints in the gateway logs before comparing results.
Timings start inside the pod, excluding kubectl exec startup. The difference between
modes includes buffering, queueing and inference; it is not isolated classifier time.
Record deployed versions and resources alongside the output, run on an idle cluster,
and repeat in reverse mode order. There are no published comparative latency results yet.


## Things that will catch you

| | |
|---|---|
| **DeepGEMM crash-loops Qwen FP8** | vLLM 0.27.1 auto-selects the DEEPGEMM FP8 MoE backend on the RTX PRO 6000 and dies at engine init with `Assertion error (layout.hpp:60): Unknown SF transformation`. `VLLM_USE_DEEP_GEMM=0` and `VLLM_MOE_USE_DEEP_GEMM=0` fix it. |
| **Qwen needs a tool parser** | kagent sends `tools` on every request and vLLM defaults `tool_choice` to `auto`, so without `--enable-auto-tool-choice --tool-call-parser=qwen3_coder` it 400s on every agent request while the routing still looks fine. |
| **The transformation runs before the ExtProc** | In one `PreRouting` policy the transformation is evaluated first, and the processor's body rewrite lands after the backend pinned its model. Both in one policy gives a request whose route came from the regex and whose body came from the router, and a 400 when they disagree. The semantic policy therefore has no transformation. |
| **The header is `x-selected-model`** | `x-vsr-selected-model` is a *response* header with the same value. Matching it gives a route that never matches, with no error anywhere. |
| **Read both content shapes** | `content` can be a string or a list of typed parts. curl sends a string, ADK and LiteLLM agents send parts. Matching only the string shape silently sends all agent traffic to the default model. |
| **The gateway Service defaults to LoadBalancer** | Apply the Gateway on its own and the controller provisions a public cloud load balancer in front of an unauthenticated LLM endpoint, and nothing on the Gateway says it did. `yaml/05` pins the Service to `ClusterIP` with an `AgentgatewayParameters` and `spec.infrastructure.parametersRef`. |
| **The vSR chart PVC** | defaults to a `standard` StorageClass that does not exist on EKS, so the pod reports an unbound claim rather than a config error. `yaml/70` sets `gp3`. |
| **kagent agents need a skill** | An agent card with no `a2aConfig.skills` list is rejected by the runtime at startup, and the failure looks like a broken image rather than a rejected card. On a cluster that reserves Agent creation to the kagent control plane, add `--as=system:serviceaccount:kagent:kagent-controller`; this one does not. |

## When the topic is not enough

Routing on the topic runs out when two prompts share one. That is
[Part 2](../agentgateway-inference-signal-routing-eks/), which runs
on this cluster and these two models and adds a second signal to the router.

## Teardown

```bash
AWS_PROFILE=<profile> ./scripts/quick.sh teardown
```

Removes this lab's objects and scales back to **one** GPU node, not zero, because part
1's Mistral is on the other card. The `qwen-weights` PVC is left in place: it holds
31 GB that costs another download to replace.
