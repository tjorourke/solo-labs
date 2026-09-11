# agentgateway as an inference gateway, Part 2: prefill and decode on your own GPUs

[Part 1](../agentgateway-inference-load-balancing-eks/) puts one model on two cards and
asks which card should take the next request. Both cards do the same job, and the
scheduler picks between them.

This lab gives them different jobs. Once the model runs on GPUs you own, you get to decide
what each card does: one only reads prompts, the other only generates answers. The KV cache
moves between them over the network, and a scheduler decides, per request, whether that is
worth doing.

It layers on Part 1 and keeps the cluster, the two GPUs, the weights on their volumes and
the Gateway exactly as they were. No new infrastructure, no third card, no re-download,
and **nothing changes on the gateway at all**.

**Editions.** The gateway's configuration is not touched, so whichever edition of
agentgateway is already running keeps working. The only file with an edition-specific
field anywhere in this lab is the one it does not apply.

## Why the two halves are different work

An LLM answers in two phases, and they stress completely different parts of a GPU.

| | Prefill | Decode |
|---|---|---|
| What it does | one forward pass over the whole prompt | one token at a time from the KV cache |
| Bottleneck | compute, the card's FLOPs | memory bandwidth, HBM to on-chip |
| Length | one pass, however long the prompt | one pass per output token |
| Scales with | input length | output length and concurrency |

Run them on one engine and they interfere. A 12,000 token prompt arrives, takes the card
for a full forward pass, and every conversation already generating stops dead until it
finishes. The user who asked the long question waits, which is fair. Everyone else waits
too, which is not.

Split them and the long prefill lands on a card that is not generating anything, so the
stall does not happen. That is what this lab measures: **inter-token latency on short
requests while a long one is in flight**, not time to first token.

Being straight about that: disaggregation does **not** improve time to first token, and
on this hardware it makes it worse. The prompt goes to one card, the KV blocks come back
over the network, and only then does generation begin. Anyone leading with TTFT on a
two-card P/D demo is measuring the wrong thing.

## What actually happens to a request

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

Three consequences.

**The request always lands on the decode worker.** Not on the prefill worker, not on a
proxy in the middle. The decode profile always runs and always returns an endpoint,
because every request has to end up somewhere, and the place it ends up is where the
answer is generated from.

**Disaggregation is a per-request decision, not a deployment mode.** The decider looks at
how much of the prompt is not already in cache. A short follow-up in a warm conversation
runs prefill and decode locally on the decode worker. A cold 8,000 token document goes out
to the prefill worker. The same two pods serve both, with no redeploy.

**The gateway does not know any of this happened.** It calls an Endpoint Picker, gets an
endpoint and some headers back, and dials it, which is what it does in Part 1. The picker
changed; the gateway did not.

## The Endpoint Picker is not the same one

Part 1 runs the upstream picker from the Gateway API Inference Extension. It cannot do
this, and not because it is behind. There is no prefill/decode plugin in GIE v1.4.0 at
all: its scorers are queue, kv-cache-utilization, running-requests-size, lora-affinity,
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
at this picker instead of the upstream one. Swapping the brain out from under an
InferencePool is a supported thing to do, and it is the part worth noticing: the picker is
a plugin point, not a fixed component.

One pool covers **both** roles. The role filters inside the picker separate them. Split
prefill and decode into two pools and the disagg handler has nothing to choose between.

## The A/B, and why it is a fair one

`scripts/decider.sh` changes exactly one number:

```bash
./scripts/decider.sh 999999   # nothing is worth disaggregating: monolithic
./scripts/decider.sh 16       # almost everything is: disaggregated
```

Same two pods, same route, same picker, same gateway, same prompts. The monolithic run is
not a different deployment, it is the same deployment declining to use the second card.
That makes it an honest baseline for what disaggregation bought, which a separately built
comparison would not be.

Restarting the picker between runs is deliberate: it empties the prefix index, so neither
run inherits what the other taught it.

## What proves it worked

Not a 200. `failureMode: FailOpen` means a picker that never ran still serves every
request, monolithically, while the route reports Accepted and the Gateway reports
Programmed.

The proof is the shape of each pod's counters, which a healthy-looking 200 cannot fake:

```
pod               requests   prompt tok   gen tok
vllm-prefill             7        31266         7     <- all the prompt, exactly 1 token each
vllm-decode             12        31355      1631     <- all the generation
```

Those are real numbers from a run on this cluster. Seven requests, seven generated
tokens: a prefill worker reads a prompt and emits a single token before handing off.
The monolithic arm of the same comparison:

```
pod               requests   prompt tok   gen tok
vllm-prefill             0            0         0
vllm-decode             15        46981      2233
```

A prefill worker reads prompts and emits a single token. A decode worker generates. If the
prefill pod's `prompt_tokens_total` did not move, nothing was disaggregated, whatever else
anything says. `scripts/pd.py` reads those counters before and after each run and prints a
verdict from them.

The other evidence is the picker's own log at `--v 4`, which names the profiles it ran per
request. Two profile names is a disaggregated request; one is monolithic.

## What it bought, measured

Long prompts run in the background; short requests are measured alongside them and the
gaps between their tokens recorded. Two `g7e.2xlarge`, KV transfer over TCP:

| Run | p50 gap | p95 gap | worst gap | TTFT p50 |
|---|---|---|---|---|
| Monolithic, run 1 | 9 ms | 11 ms | **729 ms** | 0.04 s |
| Monolithic, run 2 | 9 ms | 10 ms | **114 ms** | 0.04 s |
| Disaggregated, run 1 | 9 ms | 10 ms | **20 ms** | 0.09 s |
| Disaggregated, run 2 | 9 ms | 11 ms | **22 ms** | 0.09 s |

Read the worst-gap column. The steady state is identical at 9 ms either way, because
disaggregation does not make decode faster. What it does is bound the tail: disaggregated
it stayed at 20 and 22 ms across runs, monolithic it spiked to 114 ms and 729 ms
depending on where the long prefill landed. TTFT moved the wrong way, 0.04 s to 0.09 s,
which is the transfer being paid for.

So the trade is a predictable stream for everyone, bought with a slower first token for
whoever sent the long prompt.

## Hardware, honestly

The KV cache has to get from one card to the other, and how fast that is dominates whether
any of this pays. NIXL supports TCP and llm-d's own guidance is that high bandwidth
networking (InfiniBand, RoCE, EFA) is strongly recommended for production.

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

So the KV transfer here runs over UCX on TCP. It works, and it is a supported
configuration, and it is not the one you would build on.

**To make it production-shaped**, change the nodegroup to two `g7e.8xlarge` and switch the
NIXL backend, which is what llm-d's own AWS overlay does:

```yaml
# in yaml/00-prefill.yaml and yaml/01-decode.yaml
- --kv-transfer-config
- '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'
securityContext:
  capabilities:
    add: ["IPC_LOCK"]          # EFA needs it to pin memory
```

That is $18.32/hr for the pair instead of $11.70.

## Two cards is not where P/D pays

Say this out loud before showing anyone the numbers, because the mechanism works perfectly
at this size and the economics do not.

llm-d's own guidance is to reach for disaggregation on medium-to-large models, long inputs
relative to outputs (10k in, 1k out, not 200 in, 200 out) and sparse MoE architectures. The
reference deployment in their guide is eight prefill workers at TP=1 feeding two decode
workers at TP=4, on `gpt-oss-120b`, over RDMA. It works by specialising a fleet: many
cheap prefill workers, fewer heavily parallel decode workers, and the xPyD ratio tuned to
your traffic's input-to-output ratio.

One prefill and one decode is the smallest arrangement that can demonstrate the mechanism
and the largest that fits on two cards. What it can show honestly:

- the decision being made per request, and the header that carries it
- the KV cache actually moving, visible in each pod's counters
- decode's inter-token latency holding up while a long prefill runs elsewhere

What it cannot show is throughput per GPU improving, because there is no fleet to
specialise and no ratio to tune. The model helps as much as it can here:
Qwen3-Coder-30B-A3B is a sparse MoE, which is on llm-d's list, and the lab drives 12,000
token prompts against 128 token answers, which is the input-heavy shape that benefits. Two
cards over TCP is still two cards over TCP.

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

No cloud resources are created by this lab, so teardown costs nothing and frees nothing.
Stop the meter with Part 1's `./scripts/gpu.sh down`.

## Things that will catch you

| | |
|---|---|
| **`--allow-experimental-plugins`** | Without it the picker starts, reads the same config, logs no error, and runs a single default profile. Every request serves monolithically and the only symptom is a prefill pod whose counters never move. `01-deploy.sh` greps the EPP log for the handler rather than trusting the rollout. |
| **Block sizes must match** | `--block-size=128` on both sides. NixlConnector refuses a pairing whose block sizes differ, and the error names neither pod. 128 rather than the default 16 because a KV transfer moves whole blocks and fewer, bigger transfers is what a TCP path wants. |
| **Multi-Attach on the weight volumes** | gp3 is ReadWriteOnce. Part 1's StatefulSet has to be scaled to zero and its pods actually gone before these Deployments can mount the same volumes, and "scaled" is not "gone". Apply them too early and both pods sit in ContainerCreating on "Multi-Attach error for volume", which reads like a storage fault rather than a sequencing one. |
| **`VLLM_NIXL_SIDE_CHANNEL_HOST`** | Must be the pod IP, from the downward API. vLLM publishes this address in the KVTransferParams it returns, and decode dials it over ZMQ for the NIXL metadata. Leave it unset and it advertises something unroutable from another pod, and every transfer times out with nothing in either log naming the address. |
| **Keep-alive mismatch** | vLLM's default HTTP keep-alive is 5s and the sidecar's idle connection timeout is 90s, so a reused connection gets a TCP RST. The symptom is intermittent 502s under load that vanish when you retry by hand. `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=120` on the prefill worker. |
| **`/dev/shm` at the default 64 MB** | NIXL and UCX stage transfers through shared memory. Too small and it is a mid-transfer crash, not a startup error. Both pods mount a 20 Gi memory-backed emptyDir. |
| **The first request of a pair is slow** | A cold NIXL pairing costs a handshake of a few seconds, once per prefill/decode pair. `pd.py` warms up with long requests before measuring, and the route's timeout is 600s so a clipped handshake does not look like a failure. |
| **`appProtocol: http2` on the EPP Service** | ExtProc is gRPC. Without it the gateway may negotiate HTTP/1.1, every scheduling call fails, and FailOpen turns that into silent monolithic serving. |
| **The engine port is not the pod port** | The sidecar listens on 8000 and vLLM on 8200. Anything that dials 8200 directly bypasses the sidecar and can only ever run monolithic, including a readiness probe pointed at the wrong one. The probe here deliberately targets 8200, because probing through the sidecar reports Ready about eight minutes before the model has loaded. |
| **The role label is what the filters match on** | `llm-d.ai/role: prefill` and `decode` are what `prefill-filter` and `decode-filter` select on. Get one wrong and a profile finds no candidates, which surfaces as everything quietly running monolithic. |
| **NIXL needs to be in the image** | The published `vllm/vllm-openai` release images are built with `INSTALL_KV_CONNECTORS=true`, which installs nixl 1.3.1. The Dockerfile's own default for that arg is `false`, so an image built from source without it has no NixlConnector and fails at engine init on an unknown connector. Check before swapping the image. |

## Versions

llm-d inference scheduler `v0.10.0` (`llm-d-router-endpoint-picker`,
`llm-d-router-disagg-sidecar`), vLLM 0.27.1 with nixl 1.3.1, on the cluster and
agentgateway build Part 1 leaves behind. Validated builds are recorded in the lab's
**Versions** footer (see `lab-tested-versions.json`).
