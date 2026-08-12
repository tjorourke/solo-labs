# sovereign-ai-uk-eks

An open-weights European model, running on UK infrastructure, with agentgateway in
front of everything. Built for an EMEA webinar on AI security and sovereignty.

Three claims the build has to physically prove, not assert:

1. The weights and the inference never leave `eu-west-2`.
2. Nothing reaches the model except through agentgateway, and the gateway knows who
   the caller is.
3. Every call produced evidence a compliance team can read.

## What is running

| | |
|---|---|
| Region | AWS `eu-west-2` (London) |
| Cluster | EKS `uk-sovereign-ai`, Kubernetes **1.34** |
| VPC | dedicated, `10.42.0.0/16`, single NAT gateway |
| System nodes | 2× `m6i.large` |
| GPU node | 1× `g6.12xlarge` (4× L4 24 GB), **on-demand**, `eu-west-2a`, **$5.84/hr** |
| Model | `mistralai/Mistral-Small-3.2-24B-Instruct-2506`, Apache 2.0 |
| Inference | vLLM, `--tensor-parallel-size 4`, bf16, 16k context |
| Weights | `models` PVC (gp3, 750 MiB/s) + mirrored to S3 in `eu-west-2` |

Kubernetes **1.34 is deliberate, not stale**. Istio 1.28 supports 1.29 to 1.34 and
phase 3 needs Solo ambient for the kagent AccessPolicy waypoint. Taking EKS 1.36
would strand the mesh work.

## Run it

```bash
# The GPU node is the only thing that costs real money.
./scripts/gpu.sh up        # ~4 min to Ready
./scripts/gpu.sh status
./scripts/gpu.sh down      # do this when you stop for the day
```

Everything else assumes the node is up:

```bash
CTX=arn:aws:eks:eu-west-2:<AWS_ACCOUNT_ID>:cluster/uk-sovereign-ai

kubectl --context $CTX apply -f yaml/00-storage.yaml       # ns, gp3-fast SC, PVC
kubectl --context $CTX apply -f yaml/10-model-sync-job.yaml # 48 GB pull, ~20 min, once
kubectl --context $CTX apply -f yaml/20-vllm.yaml           # vLLM, ~5 min to Ready
```

## Why the model is pulled the way it is

The Hugging Face repo carries **both** weight formats and totals 96 GB:
`consolidated.safetensors` (48 GB, Mistral-native) and
`model-0000X-of-00010.safetensors` (48 GB, HF sharded). vLLM here runs with
`--load-format mistral`, so only the first is needed. The sync job excludes the
sharded copy and pulls 48 GB.

The job then mirrors those weights to S3 **in `eu-west-2`**. That is not just a
faster restore path, it is the sovereignty claim: the weights entered the UK once,
deliberately, and every load since has been in-region. It is a real answer to a
real audit question, and it is worth being able to say out loud that it is
literally true.

## Traps, all hit live during the build

**Naming the Service `vllm` breaks vLLM.** Kubernetes injects legacy docker-link
env vars for every Service in the namespace, so a Service named `vllm` produces
`VLLM_PORT=tcp://10.x.x.x:8000`. vLLM reads `VLLM_PORT` as its own config expecting
an integer and the engine dies in `_get_open_port()`, with a traceback that never
mentions environment variables. Fixed with `enableServiceLinks: false`.

**24B bf16 on 4× L4 fails late, not early.** Weights are ~12 GB per GPU of 22.03
GiB usable. At `--gpu-memory-utilization=0.90` the KV cache fills the budget and
the sampler OOMs asking for 128 MiB with 75 MiB free, *after* the weights load
successfully. Runs at `0.85` with `VLLM_USE_FLASHINFER_SAMPLER=0` and
`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`.

**Spot is not usable for 4-GPU nodes in London.** EKS returns
`UnfulfillableCapacity` and spot placement scores are 1/10 in every AZ. The 7-day
spot price history is flat and cheap, which is misleading: a flat price means
nobody is bidding it up, not that there is capacity to sell. Check
`get-spot-placement-scores`, not the price chart.

**`g5.12xlarge` is not obtainable in `eu-west-2`.** Capacity-reservation probes
returned `InsufficientInstanceCapacity` in 2a and 2b, and it is not offered in 2c.
`g6.12xlarge` is available in 2a and 2b but not 2c.

**NetworkPolicy silently does nothing until you turn it on.** The vpc-cni addon
ships `--enable-network-policy=false`, while the `policyendpoints` CRD is present
and the controller runs. A NetworkPolicy applies, looks healthy, and enforces
nothing. Only ever prove it with a connection that times out, never by reading
config.

**Turning it on can strip the vpc-cni IRSA role and break the CNI.** This cost us
an afternoon, so it is worth the detail. Running

```
aws eks update-addon --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}' --resolve-conflicts PRESERVE
```

without also passing `--service-account-role-arn` left the addon's
`serviceAccountRoleArn` as `null` and removed the `eks.amazonaws.com/role-arn`
annotation from the `kube-system/aws-node` ServiceAccount. ipamd then fell back to
IMDS node-instance-role credentials, which carry `AmazonEKSWorkerNodePolicy` but
**not** `AmazonEKS_CNI_Policy`, so `ec2:DescribeNetworkInterfaces` returned 403,
ipamd never finished initialising, never served `/var/run/aws-node/ipamd.sock`, and
`aws-eks-nodeagent` panicked on connection refused.

What makes it expensive is how far the symptom sits from the cause. You see a
crashlooping nodeagent with a Go stack trace about a unix socket, and nothing
anywhere in `kubectl` output mentions IAM. **Always pass
`--service-account-role-arn` on any vpc-cni addon update**, and if the CNI ever
misbehaves check these four things in order before theorising:

```bash
kubectl -n kube-system get sa aws-node -o jsonpath='{.metadata.annotations}'
aws eks describe-addon --addon-name vpc-cni --query 'addon.serviceAccountRoleArn'
aws iam list-attached-role-policies --role-name <that role>      # wants AmazonEKS_CNI_Policy
kubectl debug node/<node> -it --image=busybox --profile=sysadmin -- \
  sh -c 'grep -i unauthorized /host/var/log/aws-routed-eni/ipamd.log | tail -5'
```

**`aws-node` stdout tells you almost nothing, and the one line that matters is easy
to misread.** A healthy ipamd logs three lines:

```
Checking for IPAM connectivity...
Copying config file...
Successfully copied CNI plugin binary and config file.
```

A broken one stops dead at the first. That boundary is a genuine signal. The real
detail is in `/var/log/aws-routed-eni/ipamd.log` **on the node**, not in
`kubectl logs`, and you need `kubectl debug node/...` to read it.

**Do not diagnose a crashloop from one `kubectl get`.** Both of the wrong theories
in this incident (netpol is fundamentally broken; live-flipping the flag versus
booting with it) came from reading a pod at a single moment. One of them was
"confirmed" by a fresh node that showed `ready=true restarts=0` and then failed
thirty seconds later. Poll for several minutes and require the restart count to
stay still before believing anything.

**`HF_HUB_ENABLE_HF_TRANSFER` is dead.** huggingface-hub 1.x moved fast transfer to
Xet. The old variable is accepted and ignored. Use `HF_XET_HIGH_PERFORMANCE=1`.

**Two environment traps on this laptop.** The shell profile exports
`AWS_PROFILE=weaveone`, so `${AWS_PROFILE:-...}` in a script silently hits the
wrong account. And the kubeconfig is shared, so any kind cluster that gets created
steals `current-context` and a bare `kubectl apply` can land somewhere else and
look successful. Scripts here hardcode the profile and pass `--context`.

## Layout

```
eks/cluster.yaml              eksctl config, VPC + both nodegroups
scripts/gpu.sh                up / down / status for the GPU node
yaml/00-storage.yaml          namespace, gp3-fast StorageClass, model PVC
yaml/10-model-sync-job.yaml   one-off 48 GB pull + S3 mirror
yaml/20-vllm.yaml             vLLM Deployment + Service
yaml/30- .. 39-               gateway lane (phase 2), NOT yet run
```

Anything numbered 30 and above is written but unvalidated. Parse-checked is not
the same as working.

## Cost

The GPU node is the entire cost at $5.84/hr. Control plane and system nodes are
about $0.30/hr. Budget roughly $400-450 for a month of build with disciplined
scale-to-zero, and check every Friday that `gpu.sh down` actually ran.
