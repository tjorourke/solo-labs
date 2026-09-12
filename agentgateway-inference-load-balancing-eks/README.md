# Inference scheduling with agentgateway, Part 1: keeping requests off overloaded GPUs

This lab runs Qwen3-Coder on two GPUs in EKS and compares agentgateway's own load balancing
with the Gateway API Inference Extension's Endpoint Picker. The picker reads model-server
metrics to choose a replica.

In the queue-depth tests it avoided the saturated replica on every request. The cache
tests were inconclusive: a random picker matched the prefix-aware profile's hit rate.

The lab creates its own EKS cluster, GPU nodes and gateway. For a simulator-based version, see
[agentgateway inference routing on kind](../agentgateway-inference-routing-kind/).

**Editions.** The lab uses OSS-compatible `InferencePool` routing on both editions
(`inferenceExtension.enabled=true` on the gateway chart), and every manifest in `yaml/`
uses only the shared `agentgateway.dev` and Gateway API Inference Extension APIs. The
one per-edition difference is the GatewayClass name, substituted at apply time, so there
is no separate `yaml-oss/`. Default is OSS; `AGW_EDITION=enterprise` runs the Solo build
and needs a licence.

## The Service baseline

With an HTTPRoute pointing at an ordinary Service, agentgateway uses **power of two
choices**. It picks two endpoints at random and takes the better-scored one. The score is:

```
health / (1 + latency * (1 + 0.1 * pending_requests))
```

The default reduces traffic to a replica that is slow or has requests outstanding, using
latency and in-flight counts observed by the gateway. The picker also reads model-server
metrics, including load from other clients. The gateway only detects that load indirectly
when it affects its own requests.

## Route to a Service or an InferencePool

The Service backend in `yaml/10-httproute-service.yaml`:

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

## Queue-depth results

`scripts/test.sh` runs the `skew` scenario. Background load is sent **directly** to one
replica, bypassing the gateway entirely, and the measured requests then go through the
gateway as normal. Both replicas remain available, with no routing hints added to the
measured requests. The picker can read the background queue directly from server metrics.

Measured on two `g7e.2xlarge`, 30 requests per run, the saturated replica being `vllm-0`:

| Route | to the idle replica | to the saturated replica |
|---|---|---|
| Service backend (P2C), run 1 | 20 | 10 |
| Service backend (P2C), run 2 | 23 | 7 |
| InferencePool, `queue-only`, run 1 | **30** | **0** |
| InferencePool, `queue-only`, run 2 | **30** | **0** |

The Service route sent 23% to 33% of requests to the saturated replica. The queue-only
profile sent all 30 requests to the idle replica in both runs. It reads
`vllm:num_requests_waiting`, so it can account for the queue before the gateway observes
a slow response.

## Cache locality: the random control matched the default

The prefix scorer favours a replica estimated to hold the prompt's cached prefix, reducing
prefill work. These tests compared its hit rate with the Service route and a random picker.

On a 96 GB card vLLM allocates about 55 GiB of KV cache, roughly 600,000 tokens. The test
corpus fits on each replica, allowing both to cache it. With that allocation, the picker
and Service backend both scored about 90%, within three percentage points of each other.

So the lab pins `--kv-cache-memory=2147483648`, which gives 21,840 tokens, and
`bench.py --docs 12` builds a corpus of about 36,000 tokens that no longer fits.

**Under that pressure the pool path roughly doubles the hit rate**, reproducibly, with
document order shuffled and at every concurrency from 1 to 6:

| Configuration | prefix hit rate |
|---|---|
| Service backend (P2C) | 37-45% |
| InferencePool, default profile (queue 2, kv 2, prefix 3) | 79-80% |
| InferencePool, **`random` picker, no scoring at all** | **79%** |

The random control matches the weighted default, so the gain cannot be attributed to the
prefix scorer. The cause remains unresolved. Shuffling document order and reducing
concurrency to 1 retained the difference; neither test explained it through document-order
correlation or the ExtProc hop slowing concurrent arrivals.

Use `epp-profiles/random.yaml` to repeat the control alongside the default profile.

## What is on the two cards

Each GPU serves a replica of Qwen3-Coder-30B-A3B-Instruct-FP8, with 31.2 GB of weights.

A StatefulSet's `volumeClaimTemplates` gives each replica its own ReadWriteOnce gp3
volume. `podManagementPolicy: Parallel`
matters: the default starts the second replica only after the first is Ready, which
serialises two 31 GB downloads.

These settings create queue and cache pressure for the tests. Size them for your workload
in production:

| Setting | Why |
|---|---|
| `--max-num-seqs=8` | Limits concurrent sequences so the test load creates a queue visible in `vllm:num_requests_waiting`. |
| `--kv-cache-memory=2147483648` | Limits the cache to 2 GiB, so the test corpus exceeds its capacity and causes evictions. |
| `--max-model-len=8192` | Has to come down with the cache. vLLM refuses to start if the cache cannot hold one request at full context length, and the error is a bare `ValueError` out of `_check_enough_kv_cache_memory` that names neither flag. |

## Prerequisites

- An AWS account, `eksctl`, `kubectl`, `helm` and the AWS CLI. The lab builds its own cluster.
- Quota and capacity for two `g7e.2xlarge` in one AZ. An On-Demand Capacity Reservation
  can reserve them for a scheduled run:

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

### Stop the GPUs or delete the cluster

```bash
./scripts/gpu.sh down          # end of session; weights stay on their volumes
./scripts/gpu.sh up            # back in a few minutes, no re-download
./scripts/quick.sh teardown    # delete the cluster entirely
```

`gpu.sh` scales to two or zero. The comparison needs two replicas; with one, every
selection returns the same endpoint.

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

Use the **gateway-side split** to check where measured requests went. A few dozen requests
on two cards are not enough to attribute every latency difference to scheduling.

```
gateway-side split (this run only, excludes any load sent direct to a replica):
    30 192.168.70.117:8000
  vllm-0   192.168.78.166
  vllm-1   192.168.70.117
```

This block uses the gateway's access log. For `skew`, the replica's own counters also
include the direct background load, so they cannot isolate the measured gateway traffic.

**Check the IP mapping printed beneath each result.** A restart can change a pod's address.
An earlier comparison used a stale mapping and attributed requests to the wrong replica.

## Troubleshooting

| | |
|---|---|
| **FailOpen can conceal an unavailable picker** | With `failureMode: FailOpen`, the gateway selects an endpoint itself if the picker is unreachable. Successful responses and Accepted/Programmed statuses do not verify picker selection. `03-pool.sh` requires `inferencepool.selected_endpoint` in the access log. |
| **The prefix counters are `_total`** | vLLM's own metrics docs list `vllm:prefix_cache_queries` and `vllm:prefix_cache_hits`. The Prometheus client appends `_total` to every Counter, so those are the logical names, not the wire names. Matching the documented name finds nothing, and a missing counter reads as zero rather than as an error, so the hit rate just prints `n/a` and looks like a model with caching switched off. |
| **`gpu_cache_usage_perc` is gone** | The V1 engine exposes `vllm:kv_cache_usage_perc`. The old name survives in older simulators and copied config, and GIE v1.4.0's default mapping uses the new one. |
| **The EPP chart asks for 4 CPU** | Sized for production scale testing. On a 4-vCPU node the picker never schedules, sits Pending, and the symptom is the FailOpen one above. `epp-profiles/base.yaml` lowers it and the cluster uses `m6i.2xlarge` platform nodes. |
| **Document order can bias cache results** | Assigning consecutive requests to one replica can reduce its working set and improve cache hits without prefix scoring. Use `bench.py --shuffle` to test for document-order correlation. |
| **A Service named `vllm` breaks vLLM** | It injects `VLLM_PORT=tcp://10.x.x.x:8000`, and vLLM parses `VLLM_*` as its own config. `enableServiceLinks: false` on the pod. |
| **An interrupted weight download looks complete** | `config.json` is small and arrives first, so testing for it makes the next run skip a half-finished pull, and vLLM dies much later on "Weight files referenced in index but missing". The init container writes a marker only after the download returns. |
| **DeepGEMM crash-loops Qwen FP8** | vLLM 0.27.1 auto-selects the DEEPGEMM FP8 MoE backend on the RTX PRO 6000 and dies at engine init with `Assertion error (layout.hpp:60): Unknown SF transformation`. `VLLM_USE_DEEP_GEMM=0` and `VLLM_MOE_USE_DEEP_GEMM=0`. |
| **`InferenceObjective` is a different API group** | `InferencePool` has graduated to `inference.networking.k8s.io/v1`; `InferenceObjective` is still `inference.networking.x-k8s.io/v1alpha2`. A `poolRef` copying the objective's own apiVersion references nothing, with no error. |
| **`huggingface_hub[hf_transfer]` no longer exists** | hub 1.31.0 dropped the extra, so pip warns and installs the base package. Harmless, and it implies an accelerated transfer that is not happening. Anonymous Hub pulls are also rate limited; set `HF_TOKEN` if 62 GB of parallel download stalls. |

## How the gateway's load balancing holds up at larger scale

This lab runs on two cards, where the question is which replica each request lands on
rather than aggregate throughput. An [upstream agentgateway
benchmark](https://agentgateway.dev/blog/2026-08-20-benchmarking-agentgateway-epp-proxy-overhead/),
run for Google Summer of Code 2026 on 16 H100s serving Qwen3-32B across eight vLLM
replicas, measures the other end of the same question: what routing through agentgateway is
worth against a plain Kubernetes Service with kube-proxy round-robin.

At 60 queries per second, routing through agentgateway rather than round-robin raised peak
output from 6,910 to 16,178 tokens per second, and completed requests per second from 6.70
to 16.52. Time to first token fell from 62.9s to 0.1s at the median, and from 135.6s to
0.2s at the 90th percentile. Round-robin was piling requests onto replicas that were
already saturated, which is the same failure this lab watches for on two cards.

The gap is not a fixed proxy cost. At 3 QPS all setups performed alike; the difference only
opened up as load rose. Inter-token latency under load was higher through the gateway, about
50ms against 30ms, which the authors attribute to vLLM keeping the GPUs fully batched rather
than to gateway overhead.

Those figures are from the upstream benchmark on H100s, not from this lab's two
`g7e.2xlarge` cards. They measure agentgateway's routing against round-robin; the tests
above measure the Endpoint Picker against agentgateway's own power of two choices, a finer
comparison on top of that.

## Next: prefill and decode on separate GPUs

Each replica runs prefill and decode on the same card here.
Splitting them across cards is
[Part 2](../agentgateway-inference-disaggregation-eks/), which needs a different Endpoint
Picker: upstream GIE v1.4.0 has no prefill/decode plugin at all.

## Versions

Pinned in the repo-root `versions.env`. Validated builds are recorded in the lab's
**Versions** footer (see `lab-tested-versions.json`).
