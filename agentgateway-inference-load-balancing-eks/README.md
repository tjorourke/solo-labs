# Two GPUs, one model: what the Endpoint Picker is actually for

One model served on two GPU cards behind one endpoint, and a gateway that has to decide
which card takes the next request. This lab measures what the Gateway API Inference
Extension's Endpoint Picker buys you over the load balancing agentgateway already does,
on two real cards.

Measured rather than assumed: **the queue signal earns its place, and the case for cache
locality did not survive its own control.** Both results are below, including the one
that did not work out.

Standalone. It builds its own EKS cluster, its own GPU nodes and its own gateway, and
shares nothing with any other lab. If you want the mechanism on kind with a simulator
instead of real cards, that is
[agentgateway inference routing on kind](../agentgateway-inference-routing-kind/).

**Editions.** Nothing here needs Enterprise. `InferencePool` routing is the same on both
(`inferenceExtension.enabled=true` on the gateway chart), and every manifest in `yaml/`
uses only the shared `agentgateway.dev` and Gateway API Inference Extension APIs. The
one per-edition difference is the GatewayClass name, substituted at apply time, so there
is no separate `yaml-oss/`. Default is OSS; `AGW_EDITION=enterprise` runs the Solo build
and needs a licence.

## The baseline is not round-robin

Most write-ups on this subject, including an earlier draft of this one, open by saying
round-robin is naive. That premise is wrong.

Point an HTTPRoute at an ordinary Service and agentgateway does **not** round-robin. It
picks two endpoints at random and takes the better-scored one, which is power of two
choices, and the score is:

```
health / (1 + latency * (1 + 0.1 * pending_requests))
```

So the default already backs off a replica that is slow or has requests outstanding,
using its own observed latency and in-flight counts. Any argument for the Endpoint
Picker that starts with "round-robin is naive" is arguing against something that is not
there.

Which sharpens the real question. The gateway can see how long a replica takes to answer
it and how many of its own requests are outstanding. It cannot see anything that has not
yet turned into latency it observed, and it cannot see anything about traffic it did not
send.

## What the picker adds, and how you switch it on

One field on the route. `yaml/10-httproute-service.yaml`:

```yaml
backendRefs:
  - group: ""
    kind: Service
    name: vllm
    port: 8000
```

`yaml/11-httproute-pool.yaml`:

```yaml
backendRefs:
  - group: inference.networking.k8s.io
    kind: InferencePool
    name: vllm-pool
```

With the pool, agentgateway calls the Endpoint Picker over ExtProc, gets an endpoint back
in `x-gateway-destination-endpoint`, and dials that. The picker scrapes each model
server's `/metrics` directly, so it sees the server's own view rather than the gateway's.

The group is not optional. A `backendRef` with no `group` defaults to core, which means
Service. The pool is named `vllm-pool` and the Service `vllm` on purpose, so a dropped
group fails loudly instead of silently giving you the Service back.

## The result that holds: queue depth

`scripts/test.sh` runs the `skew` scenario. Background load is sent **directly** to one
replica, bypassing the gateway entirely, and the measured requests then go through the
gateway as normal. Nothing tells the gateway that replica is busy: no header, no drained
endpoint, nothing unhealthy. It is simply busy, and the only way to know is to read its
metrics.

That is the case the gateway's own scoring cannot cover, because the load is traffic it
never sent and never timed.

Measured on two `g7e.2xlarge`, 30 requests per run, the saturated replica being `vllm-0`:

| Route | to the idle replica | to the saturated replica |
|---|---|---|
| Service backend (P2C), run 1 | 20 | 10 |
| Service backend (P2C), run 2 | 23 | 7 |
| InferencePool, `queue-only`, run 1 | **30** | **0** |
| InferencePool, `queue-only`, run 2 | **30** | **0** |

The gateway's own balancer puts 23% to 33% of requests onto a replica that is visibly
backed up. The queue scorer puts none there. That is the lab.

It also shows why: the picker reads `vllm:num_requests_waiting` off the server, so it
knows about the queue before any of it has turned into latency the gateway could have
measured.

## The result that did not hold: cache locality

Reported in full because the control is the interesting part.

The pitch for the prefix scorer is that a replica which already holds a prompt's prefix
in KV cache can skip prefill, so the scheduler should send the request there. It is a
good story. Here is what happened.

**First, it needs cache pressure to mean anything.** On a 96 GB card vLLM takes about
55 GiB of KV cache, which is roughly 600,000 tokens. No lab workload comes close, so
nothing is ever evicted, both replicas gradually end up holding everything, and every
lookup hits regardless of who scheduled it. Measured that way, the picker and the Service
backend both scored about 90% and were within three points of each other. Cache locality
was free, so optimising for it won nothing.

So the lab pins `--kv-cache-memory=2147483648`, which gives 21,840 tokens, and
`bench.py --docs 12` builds a corpus of about 36,000 tokens that no longer fits.

**Under that pressure the pool path roughly doubles the hit rate**, reproducibly, with
document order shuffled and at every concurrency from 1 to 6:

| Configuration | prefix hit rate |
|---|---|
| Service backend (P2C) | 37-45% |
| InferencePool, default profile (queue 2, kv 2, prefix 3) | 79-80% |
| InferencePool, **`random` picker, no scoring at all** | **79%** |

The control matches the weighted default. Whatever produces that gain, it is **not** the
prefix scorer, because removing every scorer changes nothing. I could not establish the
cause: it survives shuffling the document order, which rules out my load generator's
cycling interacting with the scheduler's batch size, and it survives dropping concurrency
to 1, which rules out the ExtProc hop simply slowing arrivals and easing cache pressure.

So the number is in the lab and is not claimed as evidence for cache-aware routing.
`epp-profiles/random.yaml` is there so you can reproduce the control yourself in one
command. If you work out the mechanism, it is a better finding than the one I was
looking for.

## What is on the two cards

One model, two replicas, one card each: Qwen3-Coder-30B-A3B-Instruct-FP8, 31.2 GB of
weights.

A StatefulSet, not two Deployments. gp3 is ReadWriteOnce so the replicas cannot share a
volume, and `volumeClaimTemplates` gives each its own. `podManagementPolicy: Parallel`
matters: the default starts the second replica only after the first is Ready, which
serialises two 31 GB downloads.

Three settings are lab devices and are marked as such in the manifest. Do not copy them
into anything real:

| Setting | Why |
|---|---|
| `--max-num-seqs=8` | A 96 GB card runs far more than eight sequences at once. If it does, no concurrency ever builds a queue, `vllm:num_requests_waiting` stays at zero on both replicas, and the queue scorer has nothing to score. |
| `--kv-cache-memory=2147483648` | 2 GiB against the ~55 GiB the card would otherwise give. Without it nothing is ever evicted and the prefix scenario measures nothing. |
| `--max-model-len=8192` | Has to come down with the cache. vLLM refuses to start if the cache cannot hold one request at full context length, and the error is a bare `ValueError` out of `_check_enough_kv_cache_memory` that names neither flag. |

## Prerequisites

- An AWS account, `eksctl`, `kubectl`, `helm` and the AWS CLI. Nothing else: the lab
  builds its own cluster.
- Quota for two `g7e.2xlarge` in one AZ. London capacity moves hour to hour, so hold them
  with an On-Demand Capacity Reservation before a rehearsal rather than hoping:

  ```bash
  aws ec2 create-capacity-reservation --instance-type g7e.2xlarge \
    --instance-platform Linux/UNIX --availability-zone eu-west-2a --instance-count 2 \
    --instance-match-criteria open --end-date-type limited --end-date <when you finish>
  ```

  Always set an end date: a reservation bills the full hourly rate with nothing in it.
- About **$11.70/hr** while both GPUs are up, and a few dollars a day for the rest.

## Deploy it

```bash
export AWS_PROFILE=<your-profile>
./scripts/quick.sh up
```

| Step | What it does | Measured |
|---|---|---|
| `eksctl create cluster -f eks/cluster.yaml` | EKS 1.34, a platform nodegroup and two `g7e.2xlarge` in one AZ | 14 min |
| `scripts/01-gateway.sh` | default StorageClass, Gateway API, GIE CRDs, agentgateway with the inference extension on | 2 min |
| `scripts/02-models.sh` | the StatefulSet and the load generator; first run pulls 31 GB per replica, in parallel | 16 min |
| `scripts/03-pool.sh` | Gateway, InferencePool, Endpoint Picker, route, and the check that the picker is really in the path | 1 min |

The **standard** Gateway API channel is enough, unlike the model-routing lab next door,
which needs the experimental channel for ExtProc policies. This one never writes an
ExtProc policy: the picker is reached over ExtProc too, but the gateway wires that itself
from the InferencePool.

### Stopping the meter

```bash
./scripts/gpu.sh down          # end of session; weights stay on their volumes
./scripts/gpu.sh up            # back in a few minutes, no re-download
./scripts/quick.sh teardown    # delete the cluster entirely
```

`gpu.sh` scales to two or zero, never one. One card leaves the lab running and pointless:
the picker scores a pool of one replica and returns it every time, which looks exactly
like a working scheduler.

## Running it

```bash
./scripts/test.sh            # the skew scenario, which is the one that holds
./scripts/test.sh mixed
./scripts/test.sh prefix     # read the caveat above before believing the number
```

By hand:

```bash
./scripts/route.sh service          # the gateway's own P2C
./scripts/route.sh pool             # the Endpoint Picker decides
./scripts/profile.sh                # list the scheduling profiles
./scripts/profile.sh queue-only     # switch to one
./scripts/bench.sh skew --requests 30 --concurrency 6
./scripts/metrics.sh watch          # the gauges the picker reads, live
./scripts/where.sh 40               # which replica served the last 40, per the gateway
```

### Reading the output

Read the **gateway-side split**, not the percentiles. On two cards with a few dozen
requests, latency moves for all sorts of reasons that have nothing to do with the
scheduler.

```
gateway-side split (this run only, excludes any load sent direct to a replica):
    30 192.168.70.117:8000
  vllm-0   192.168.78.166
  vllm-1   192.168.70.117
```

That block is computed from the gateway's own access log rather than from the pods'
counters, and for `skew` it is the only trustworthy number: the background load is sent
direct to a replica, so that replica's counters include traffic the gateway never saw.

**Check the IP mapping printed underneath every time.** Restarting a pod gives it a new
address, and reading a later run against an earlier mapping will tell you the baseline
beat the picker when it did not. That is a mistake this lab made.

## Things that will catch you

| | |
|---|---|
| **FailOpen hides a broken picker** | `failureMode: FailOpen` is right for inference and is also the setting that will cost you an afternoon. If the picker is unreachable the gateway quietly picks an endpoint itself: every request succeeds, the route is Accepted, the Gateway is Programmed, and you are measuring the Service path. `03-pool.sh` refuses to finish unless `inferencepool.selected_endpoint` appears in the access log. |
| **The prefix counters are `_total`** | vLLM's own metrics docs list `vllm:prefix_cache_queries` and `vllm:prefix_cache_hits`. The Prometheus client appends `_total` to every Counter, so those are the logical names, not the wire names. Matching the documented name finds nothing, and a missing counter reads as zero rather than as an error, so the hit rate just prints `n/a` and looks like a model with caching switched off. |
| **`gpu_cache_usage_perc` is gone** | The V1 engine exposes `vllm:kv_cache_usage_perc`. The old name survives in older simulators and copied config, and GIE v1.4.0's default mapping uses the new one. |
| **The EPP chart asks for 4 CPU** | Sized for production scale testing. On a 4-vCPU node the picker never schedules, sits Pending, and the symptom is the FailOpen one above. `epp-profiles/base.yaml` lowers it and the cluster uses `m6i.2xlarge` platform nodes. |
| **Cyclic document order flatters any scheduler** | A scheduler that assigns requests in runs gives one replica a run of *consecutive documents*, which is a smaller working set than the corpus and fits in a cache the whole corpus would not. It looks exactly like cache-aware routing. `bench.py --shuffle` removes the correlation, and every comparison worth believing uses it. |
| **A Service named `vllm` breaks vLLM** | It injects `VLLM_PORT=tcp://10.x.x.x:8000`, and vLLM parses `VLLM_*` as its own config. `enableServiceLinks: false` on the pod. |
| **An interrupted weight download looks complete** | `config.json` is small and arrives first, so testing for it makes the next run skip a half-finished pull, and vLLM dies much later on "Weight files referenced in index but missing". The init container writes a marker only after the download returns. |
| **DeepGEMM crash-loops Qwen FP8** | vLLM 0.27.1 auto-selects the DEEPGEMM FP8 MoE backend on the RTX PRO 6000 and dies at engine init with `Assertion error (layout.hpp:60): Unknown SF transformation`. `VLLM_USE_DEEP_GEMM=0` and `VLLM_MOE_USE_DEEP_GEMM=0`. |
| **`InferenceObjective` is a different API group** | `InferencePool` has graduated to `inference.networking.k8s.io/v1`; `InferenceObjective` is still `inference.networking.x-k8s.io/v1alpha2`. A `poolRef` copying the objective's own apiVersion references nothing, with no error. |
| **`huggingface_hub[hf_transfer]` no longer exists** | hub 1.31.0 dropped the extra, so pip warns and installs the base package. Harmless, and it implies an accelerated transfer that is not happening. Anonymous Hub pulls are also rate limited; set `HF_TOKEN` if 62 GB of parallel download stalls. |

## What this lab does not do

Prefill and decode run on the same card here, which is how almost everyone runs vLLM.
Splitting them across cards is
[Part 2](../agentgateway-inference-disaggregation-eks/), which needs a different Endpoint
Picker: upstream GIE v1.4.0 has no prefill/decode plugin at all.

## Versions

Pinned in the repo-root `versions.env`. Validated builds are recorded in the lab's
**Versions** footer (see `lab-tested-versions.json`).
