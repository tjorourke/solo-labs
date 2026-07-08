# agentgateway inference routing on kind

Route LLM traffic to a **self-hosted model pool** through agentgateway, and let the
Gateway API Inference Extension (GIE) Endpoint Picker choose which replica serves
each request from live vLLM metrics: **KV-cache usage and queue depth**. That is
the caching story on a laptop. Route to the replica that already holds the
prompt's prefix in its KV cache so it skips prefill, and away from a saturated
one. No GPU required.

One kind cluster:

- **agentgateway** as the Gateway API data plane (`inferenceExtension.enabled=true`).
- **Gateway API Inference Extension v1.4.0**. `InferencePool` (v1) is the routable
  backend, the **Endpoint Picker (EPP)** that scores replicas, and `InferenceObjective`
  for serving priority.
- **Two model servers**, the llm-d inference simulator standing in for vLLM. Each
  pins its `vllm:gpu_cache_usage_perc` and `vllm:num_requests_waiting` gauges from a
  mounted config, so the routing decision is deterministic and you can flip it on cue.

## Run it

Enterprise (default, needs a license):

```bash
export SECRETS_FILE=/path/to/secrets-envs.sh   # exports AGENTGATEWAY_LICENSE_KEY
./scripts/quick.sh up
./scripts/quick.sh test        # fire requests, see which replica the EPP picked
```

OSS (no license):

```bash
AGW_EDITION=oss ./scripts/quick.sh up
```

Tear down: `./scripts/quick.sh teardown`.

## The demo, by hand

```bash
# 1. Both replicas up: pool-a COLD (kv-cache 0.10), pool-b HOT (0.90).
./demo-scripts/route-test.sh 8      # all traffic lands on pool-a (cold)

# 2. Saturate pool-a, free pool-b.
./demo-scripts/set-kv.sh a 0.95 9 6
./demo-scripts/set-kv.sh b 0.05 0 1
sleep 6                              # let the EPP re-scrape
./demo-scripts/route-test.sh 8      # traffic has moved to pool-b

# 3. Reset for the next run.
./demo-scripts/reset.sh
```

Or drive the whole thing from the notebook: `demo.ipynb` (Bash kernel; run
`./demo-scripts/notebook-kernel.sh` once to register it).

## How the routing is wired

```
client ──/v1/chat/completions──▶ Gateway (agentgateway)
                                    │  HTTPRoute backendRef ─▶ InferencePool (group inference.networking.k8s.io)
                                    ▼
                              Endpoint Picker (EPP)  ── scrapes ──▶ vllm:gpu_cache_usage_perc
                                    │                               vllm:num_requests_waiting
                     picks the best replica by score
                          ┌─────────┴─────────┐
                     pool-a (cold)        pool-b (hot)
```

The HTTPRoute backend is **not** a Service. It is the `InferencePool`. agentgateway
hands endpoint selection to the EPP, which is the whole point: routing follows the
model servers' real load, not round-robin.

## Editions

Every manifest in `yaml/` is edition-neutral (shared `agentgateway.dev` + GIE APIs).
The only per-edition difference is the GatewayClass name (injected at apply time)
and the Helm chart:

| | GatewayClass | chart | license |
|---|---|---|---|
| Enterprise (default) | `enterprise-agentgateway` | `enterprise-agentgateway` | yes |
| OSS (`AGW_EDITION=oss`) | `agentgateway` | `cr.agentgateway.dev/charts/agentgateway` | no |

So there is no separate `yaml-oss/`; the same `yaml/` runs on both.

## Versions

Pinned in the repo-root `versions.env`. Validated builds are recorded in the lab's
**Versions** footer (see `lab-tested-versions.json`): agentgateway (Enterprise
`v2.3.4` / OSS `v1.3.1`), GIE `v1.4.0`, Gateway API `v1.5.1`, llm-d inference
simulator `v0.5.0`.
