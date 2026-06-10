# vLLM Semantic Router on agentgateway (kind)

A single-cluster kind lab that puts the **vLLM Semantic Router** inline, as a
gRPC ExtProc service, in front of a vLLM backend serving a base model and six
mock LoRA adapters. Clients always send `"model": "auto"` to one endpoint. The
router classifies the prompt and rewrites the request body to pick the right
adapter; agentgateway forwards the mutated request. The router decides, the
gateway enforces.

This reproduces the masterthemesh KB article *"vLLM Semantic Router on
agentgateway"* and runs on the **OSS upstream agentgateway**
(`cr.agentgateway.dev`, the Linux Foundation project).

## Why OSS upstream agentgateway (not Solo)

This is the one place the distribution matters. The router works by having the
gateway buffer the request body, hand it to the router over ExtProc, and forward
the body the router rewrites. That requires ExtProc body-mode control on the
policy: `processingOptions` with `requestBodyMode: Buffered` and
`allowModeOverride: true`.

Solo's agentgateway CRDs (both the OSS-packaged `agentgateway.dev` set and the
Enterprise `enterpriseagentgateway.solo.io` set) expose `extProc.backendRef`
only, with no `processingOptions`. Tested on Solo Enterprise v2.3.3: the router
classifies the prompt correctly, but the rewritten body is dropped and the
backend returns `503 ... EOF while parsing` on an empty body. The
`processingOptions`/`allowModeOverride` fields exist only on the upstream
agentgateway CRD (`cr.agentgateway.dev`, v1.3.0-alpha.1+), so that is what this
lab installs.

## What gets deployed

| Component | Where | Purpose |
|---|---|---|
| OSS agentgateway | `agentgateway-system` | Gateway API proxy, runs the router as ExtProc |
| vLLM simulator (`llm-d-inference-sim`) | `default` | base-model + 6 mock LoRA adapters on `:8000` |
| vLLM Semantic Router | `agentgateway-system` | gRPC ExtProc classifier on `:50051` |
| Gateway + HTTPRoute + AgentgatewayBackend + AgentgatewayPolicy | `agentgateway-system` | the data path |

The adapters are names only, no weights and no training. That is all the
routing path needs to prove out.

## Prerequisites

- `kind`, `kubectl`, `helm`, `docker` (Docker Desktop / OrbStack running)
- No license and no registry auth: the OSS charts pull anonymously.
- `HF_TOKEN` (optional but recommended) — a HuggingFace token. On first start
  the router downloads several GB of classification models from the HF Hub.
  Unauthenticated pulls are rate-limited and slow; an `HF_TOKEN` makes the
  download much faster. Without it, expect the router to sit at `0/1` for a
  while on first run (it is downloading, not stuck).

## Run it

```bash
export HF_TOKEN=hf_...                      # optional, but much faster first start
./scripts/quick.sh up
./scripts/quick.sh test
```

First start is slow: the router pulls several GB of classification models into a
PVC before it binds `:50051`, so the pod stays `0/1` during the download. The
install step polls for up to 30 minutes (`SEMANTIC_ROUTER_TIMEOUT` to override)
and prints the bytes on disk as it goes. If `quick.sh up` ever exits early, it
is idempotent: re-run it, or run the remaining step with `./scripts/05-routing.sh`.

## What a correct run looks like

`test.sh` sends prompts in different categories, each with `"model": "auto"`,
and reads the router's decision from the `x-vsr-*` response headers. Distinct
adapters per category is the proof: the router rewrote the body and the gateway
forwarded it.

```
math       → category=math         adapter=math-expert
law        → category=law          adapter=law-expert
biology    → category=health       adapter=science-expert
business   → category=business     adapter=social-expert
history    → category=history      adapter=humanities-expert
```

Manual request:

```bash
./scripts/port-forward.sh
curl -i -X POST http://localhost:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is the derivative of x^3?"}]}'
# response headers carry x-vsr-selected-category / x-vsr-selected-model
```

Teardown: `./scripts/quick.sh teardown`.

## The CRD shapes

All verified against the OSS `agentgateway-crds` chart v1.3.0-alpha.1.

AI backend: the model is omitted on purpose so the model name the router writes
into the body wins.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
spec:
  ai:
    provider:
      openai: {}
      host: vllm-llama3-8b-instruct.default.svc.cluster.local
      port: 8000
```

ExtProc policy: `processingOptions` is what makes body rewriting work.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: vllm-gateway
  traffic:
    extProc:
      backendRef:
        name: semantic-router
        namespace: agentgateway-system
        port: 50051
      processingOptions:
        requestHeaderMode: Send
        requestBodyMode: Buffered
        responseHeaderMode: Send
        responseBodyMode: Buffered
        allowModeOverride: true
```

For large prompts, switch `requestBodyMode` to `FullDuplexStreamed`.

## Troubleshooting

```bash
# Router decision logs (classification + chosen adapter)
kubectl --context kind-vllm-sr -n agentgateway-system logs deploy/semantic-router

# Gateway programmed? policy + route accepted?
kubectl --context kind-vllm-sr -n agentgateway-system get gateway vllm-gateway
kubectl --context kind-vllm-sr -n agentgateway-system describe agentgatewaypolicy semantic-router-extproc
kubectl --context kind-vllm-sr -n agentgateway-system describe httproute semantic-router-vllm

# Backend serving + adapters loaded?
kubectl --context kind-vllm-sr -n default exec deploy/vllm-llama3-8b-instruct -- wget -qO- localhost:8000/v1/models
```

If every prompt routes to the same adapter, or you get `503 EOF while parsing`,
the body rewrite did not take effect. On OSS agentgateway, confirm
`processingOptions.allowModeOverride: true` is set on the policy. On Solo
agentgateway this is expected: that CRD has no `processingOptions` (see "Why OSS
upstream agentgateway" above).

## Working with real LoRA adapters

The simulator declares adapter names with no weights. For production, swap it
for real vLLM serving real adapter files. The contract that makes routing work
is name matching: the adapter name must be identical across how vLLM loaded it,
what the router config emits per category, and what `GET /v1/models` reports. A
mismatch returns "model not found". An adapter must be trained against the same
base model being served, or vLLM refuses to load it.

```bash
vllm serve base-model \
  --enable-lora --max-loras 6 --max-lora-rank 16 \
  --lora-modules math-expert=/models/math-lora law-expert=/models/law-lora
```

## Files

```
kind/cluster.yaml                       kind cluster (name: vllm-sr)
scripts/01-cluster.sh                   kind + Gateway API CRDs
scripts/02-agentgateway.sh              OSS upstream agentgateway (anonymous pull)
scripts/03-vllm-backend.sh              vLLM simulator + Service
scripts/04-semantic-router.sh           upstream router (vendored values)
scripts/05-routing.sh                   gateway + backend + route + extproc policy
scripts/{quick,port-forward,test}.sh    orchestrate / expose / verify
yaml/vllm/deployment.yaml               simulator Deployment + Service
yaml/agentgateway/*.yaml                gateway, backend, httproute, extproc policy
yaml/semantic-router/values.yaml        vendored upstream agentgateway preset
```
