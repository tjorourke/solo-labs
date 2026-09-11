# Inference scheduling with agentgateway, Part 2: smoother responses under load

[Part 1](../agentgateway-inference-load-balancing-eks/) runs one model on two GPUs, with
each replica handling complete requests. This lab separates prefill and decode across
those GPUs, using llm-d to select workers and NIXL to transfer KV-cache blocks.

It reuses Part 1's cluster, weight volumes and gateway configuration. The scheduler
decides per request whether to separate the phases or run both on the decode worker.

**Editions.** The lab uses the edition of agentgateway installed by Part 1. Its deployment
steps do not change the gateway configuration.

## Prefill and decode

Prefill builds the attention keys and values stored in the KV cache. Decode uses that
state to generate subsequent tokens. Their typical bottlenecks differ, although model,
batch size and context length affect both:

| | Prefill | Decode |
|---|---|---|
| What it does | one forward pass over the whole prompt | one token at a time from the KV cache |
| Bottleneck | compute, the card's FLOPs | memory bandwidth, HBM to on-chip |
| Length | one pass, however long the prompt | one pass per output token |
| Scales with | input length | output length and concurrency |

When both phases share a GPU, prefill work can delay decode steps for requests already
streaming. The size of the gaps depends on how the engine batches and schedules the work.

Moving prefill to another GPU reduces that interference, but adds a KV-cache transfer.
This lab measures **inter-token latency on short requests while long prompts run in the
background**, along with time to first token (TTFT). In these runs, the longest gaps
decreased while median TTFT increased.

## Request flow

```
client ──▶ agentgateway ──ExtProc──▶ llm-d Endpoint Picker
                                         │  1. decode profile: always runs, picks a decode pod
                                         │  2. prefill profile: runs only if the decider says
                                         │     this prompt is worth disaggregating
                                         ▼
                        x-gateway-destination-endpoint: <decode pod>
                        x-prefiller-host-port:          <prefill pod>   (only if 2 ran)
                                         │
                                         ▼
                              decode pod's routing sidecar
                                         │
              ┌──────────────────────────┴───────────────────────┐
              │ header absent                    header present  │
              ▼                                                  ▼
      run prefill + decode                    POST prompt to the prefill worker with
      locally, as normal                      do_remote_decode=true
                                              ◀── KVTransferParams (host, port, block ids)
                                              hand those to the local engine with
                                              do_remote_prefill=true
                                              engine pulls the KV blocks over NIXL
                                              and generates
```

The gateway sends the request to the **routing sidecar on the decode pod**. If the picker
also selects a prefill worker, the sidecar sends the prompt there and passes the returned
KV-transfer details to the local decode engine.

The decider uses an estimate of uncached prompt tokens. Requests below its threshold run
both phases on the decode worker; those above it can use the prefill worker. Both modes
use the same deployment.

## Why this needs a different Endpoint Picker

Part 1 runs the upstream picker from the Gateway API Inference Extension. GIE v1.4.0 has
no prefill/decode plugin: its scorers are queue, kv-cache-utilization, running-requests-size, lora-affinity,
prefix-cache and predicted-latency, its pickers are max-score, random and weighted-random,
and it ships a single-profile handler. Disaggregation needs a handler that runs more than
one profile per request.

That lives in [llm-d](https://github.com/llm-d/llm-d-inference-scheduler), which builds a
different EPP binary against the same framework. `yaml/10-epp.yaml` deploys it, and the
whole policy is one ConfigMap:

```yaml
plugins:
- type: approx-prefix-cache-producer   # builds the index the decider reads
- type: prefix-cache-scorer
- type: queue-scorer
- type: prefill-filter                 # selects pods by llm-d.ai/role
- type: decode-filter
- type: max-score-picker
- type: disagg-profile-handler
  parameters:
    deciders:
      prefill: prefix-based-pd-decider
- type: prefix-based-pd-decider
  parameters:
    nonCachedTokens: 16                # the threshold this lab varies
schedulingProfiles:
- name: prefill
  plugins: [prefill-filter, max-score-picker, prefix-cache-scorer (w2), queue-scorer (w1)]
- name: decode
  plugins: [decode-filter,  max-score-picker, prefix-cache-scorer (w2), queue-scorer (w1)]
```

The `InferencePool` is the same API object as in Part 1, with `endpointPickerRef` pointing
at this picker instead of the upstream one. agentgateway continues to call the service
referenced by that field.

One pool covers **both** roles. The role filters inside the picker separate them. Split
prefill and decode into two pools and the disagg handler has nothing to choose between.

## Compare monolithic and disaggregated requests

`scripts/decider.sh` sets the uncached-token threshold:

```bash
./scripts/decider.sh 999999   # nothing is worth disaggregating: monolithic
./scripts/decider.sh 16       # almost everything is: disaggregated
```

Both runs use the same deployment and prompts. At the high threshold, both phases run
on the decode worker and the prefill GPU is idle. At the low threshold, eligible requests
use both workers. This isolates the handoff's effect, but does not compare against two
GPUs both serving complete requests.

Restarting the picker between runs clears its prefix index, so each starts without
entries from the previous run.

## Verify the prefill handoff

With `failureMode: FailOpen`, requests can succeed without the picker selecting a prefill
worker. Accepted and Programmed statuses alone do not verify disaggregation.

Compare each pod's counters before and after the run:

```
pod               requests   prompt tok   gen tok
vllm-prefill             7        31266         7     <- all the prompt, exactly 1 token each
vllm-decode             12        31355      1631     <- all the generation
```

In this run, the prefill worker processed seven requests and generated one token per
request before handing off. The monolithic run recorded:

```
pod               requests   prompt tok   gen tok
vllm-prefill             0            0         0
vllm-decode             15        46981      2233
```

The prefill pod processed no prompt tokens in the monolithic run. `scripts/pd.py` reads
the counter deltas and reports whether the prefill worker was used.

The other evidence is the picker's own log at `--v 4`, which names the profiles it ran per
request. Two profile names is a disaggregated request; one is monolithic.

## Streaming latency results

Long prompts run in the background while the client records gaps between output chunks
on short requests. A chunk can contain more than one token, so these measurements differ
from vLLM's internal per-token latency metric. TTFT here measures the wait for the first
content chunk. Two `g7e.2xlarge`, KV transfer over TCP:

| Run | p50 gap | p95 gap | worst gap | TTFT p50 |
|---|---|---|---|---|
| Monolithic, run 1 | 9 ms | 11 ms | **729 ms** | 0.04 s |
| Monolithic, run 2 | 9 ms | 10 ms | **114 ms** | 0.04 s |
| Disaggregated, run 1 | 9 ms | 10 ms | **20 ms** | 0.09 s |
| Disaggregated, run 2 | 9 ms | 11 ms | **22 ms** | 0.09 s |

Median output gaps were 9 ms in both modes. The largest gaps were 20 and 22 ms with
disaggregation, compared with 114 and 729 ms in the monolithic runs. Median TTFT increased
from 0.04 s to 0.09 s on the measured short requests. These are observations from two
runs, not an upper bound on latency.

## Network requirements for KV transfer

KV-cache transfer time depends on the network between workers. NIXL supports TCP, and
llm-d recommends high-bandwidth networking (InfiniBand, RoCE, EFA) for production.

This lab runs on Part 1's two `g7e.2xlarge`, and that size has **no EFA**. Verified in
`eu-west-2`:

| instance | GPUs | GPU memory | EFA | network | on-demand, London |
|---|---|---|---|---|---|
| `g7e.2xlarge` | 1 | 96 GB | **no** | 50 Gbit | $5.85/hr |
| `g7e.4xlarge` | 1 | 96 GB | **no** | 50 Gbit | |
| `g7e.8xlarge` | 1 | 96 GB | yes | 100 Gbit | $9.16/hr |
| `g7e.12xlarge` | 2 | 96 GB | yes | 400 Gbit | $14.40/hr |
| `g7e.24xlarge` | 4 | 96 GB | yes | 800 Gbit | |
| `g7e.48xlarge` | 8 | 96 GB | yes | 1600 Gbit | |

This lab transfers KV blocks over UCX on TCP. To evaluate EFA, use an EFA-capable instance
size such as `g7e.8xlarge` and configure the network and device support. The NIXL backend
settings below follow llm-d's AWS overlay:

```yaml
# in yaml/00-prefill.yaml and yaml/01-decode.yaml
- --kv-transfer-config
- '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'
securityContext:
  capabilities:
    add: ["IPC_LOCK"]          # EFA needs it to pin memory
```

That is $18.32/hr for the pair instead of $11.70.

## What to evaluate at larger scale

llm-d's own guidance is to reach for disaggregation on medium-to-large models, long inputs
relative to outputs (10k in, 1k out, not 200 in, 200 out) and sparse MoE architectures. The
reference deployment in their guide is eight prefill workers at TP=1 feeding two decode
workers at TP=4, on `gpt-oss-120b`, over RDMA. Prefill and decode use different parallelism
settings, with the worker ratio tuned to the workload's input-to-output ratio.

This two-card setup demonstrates the handoff and measures streaming latency under prefill
load. It does not establish a throughput-per-GPU or cost benefit. That needs a comparison
using all GPUs in both modes, with worker ratios and parallelism tuned for the workload.
Qwen3-Coder-30B-A3B is a sparse MoE model; these results cover its one-prefill, one-decode
arrangement over TCP.

## Prerequisites

[Part 1](../agentgateway-inference-load-balancing-eks/) up and working, with both GPU
nodes running and both weight volumes Bound. `00-verify-prereqs.sh` checks all of it and
stops if anything is missing.

## Deploy

```bash
./scripts/quick.sh up      # ~10 min: the weights reload from the volumes, no download
./scripts/quick.sh test    # the monolithic and disaggregated runs
```

Or by hand:

```bash
./scripts/00-verify-prereqs.sh
./scripts/01-deploy.sh
./scripts/decider.sh 999999 && ./scripts/02-test.sh
```

Teardown puts Part 1 back:

```bash
./scripts/99-restore.sh    # or: ./scripts/quick.sh teardown
```

Teardown restores Part 1's workloads and leaves its cloud resources running. Stop the GPU
instances with Part 1's `./scripts/gpu.sh down`, or use its full teardown to remove the
cluster and volumes.

## Troubleshooting

| | |
|---|---|
| **`--allow-experimental-plugins`** | Without it the picker starts, reads the same config, logs no error, and runs a single default profile. Every request serves monolithically and the only symptom is a prefill pod whose counters never move. `01-deploy.sh` greps the EPP log for the handler rather than trusting the rollout. |
| **Block sizes must match** | Set `--block-size=128` on both workers. NixlConnector rejects a pairing with different block sizes. The lab uses 128 instead of the default 16 to transfer fewer, larger blocks over TCP. |
| **Multi-Attach on the weight volumes** | gp3 volumes use ReadWriteOnce. Scale Part 1's StatefulSet to zero and wait for its pods to terminate before starting these Deployments. Otherwise the new pods can remain in ContainerCreating with "Multi-Attach error for volume" while the old attachment is active. |
| **`VLLM_NIXL_SIDE_CHANNEL_HOST`** | Must be the pod IP, from the downward API. vLLM publishes this address in the KVTransferParams it returns, and decode dials it over ZMQ for the NIXL metadata. Leave it unset and it advertises something unroutable from another pod, and every transfer times out with nothing in either log naming the address. |
| **Keep-alive mismatch** | vLLM's default HTTP keep-alive is 5s and the sidecar's idle connection timeout is 90s, so a reused connection gets a TCP RST. The symptom is intermittent 502s under load that vanish when you retry by hand. `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=120` on the prefill worker. |
| **`/dev/shm` at the default 64 MB** | NIXL and UCX stage transfers through shared memory. Too small and it is a mid-transfer crash, not a startup error. Both pods mount a 20 Gi memory-backed emptyDir. |
| **The first request of a pair is slow** | A cold NIXL pairing requires a handshake. `pd.py` sends warm-up requests before measuring, and the route allows 600s for startup and transfer. |
| **`appProtocol: http2` on the EPP Service** | ExtProc is gRPC. Without it the gateway may negotiate HTTP/1.1, every scheduling call fails, and FailOpen turns that into silent monolithic serving. |
| **Sidecar and engine ports** | The sidecar listens on 8000 and vLLM on 8200. Client traffic must use 8000 for the prefill handoff. The readiness probe checks 8200 directly so readiness depends on the model engine, rather than the sidecar starting. |
| **The role label is what the filters match on** | `llm-d.ai/role: prefill` and `decode` are what `prefill-filter` and `decode-filter` select on. Get one wrong and a profile finds no candidates, which surfaces as everything quietly running monolithic. |
| **NIXL needs to be in the image** | The published `vllm/vllm-openai` release images are built with `INSTALL_KV_CONNECTORS=true`, which installs nixl 1.3.1. The Dockerfile's own default for that arg is `false`, so an image built from source without it has no NixlConnector and fails at engine init on an unknown connector. Check before swapping the image. |

## Versions

llm-d inference scheduler `v0.10.0` (`llm-d-router-endpoint-picker`,
`llm-d-router-disagg-sidecar`), vLLM 0.27.1 with nixl 1.3.1, on the cluster and
agentgateway build Part 1 leaves behind. Validated builds are recorded in the lab's
**Versions** footer (see `lab-tested-versions.json`).
