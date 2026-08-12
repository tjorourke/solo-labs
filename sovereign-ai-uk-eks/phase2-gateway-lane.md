# Phase 2, the gateway lane

Files `yaml/30-` to `yaml/35-`, plus `yaml/39-model-restore-job.yaml` and
`scripts/test-pii-regex.py`. Phase 1 (cluster, GPU node, weights, vLLM) is
`eks/cluster.yaml` and `yaml/00-` to `yaml/20-`.

**Validation status, precisely.** Everything parses, and the agentgateway shapes are
checked field by field against the CRD schemas rather than copied from memory.

**Keycloak is genuinely validated**, not dry-run: deployed to the cluster, realm
imported, and a real minted token's `iss` and `aud` checked against the policy for all
three users.

The core-API objects have been server-side dry-run against the live cluster and the
API server accepts them: `33-models-networkpolicy.yaml`, `36-egress-lockdown.yaml` and
`39-model-restore-job.yaml`. The NetworkPolicy *mechanism* those two rely on has
separately been proven to enforce on this cluster, same-node and cross-node, with a
throwaway deny-all policy. The specific policies in `33-` and `36-` have still never
been applied.

The four agentgateway policy and backend files have **not** been validated at all,
because the CRDs are not installed on the cluster yet. `30-`, `31-`, `34-` and `35-` are
unvalidated. `32-` has had its issuer and audience proven against a real token, but the
policy itself has never been applied.

None of it has been *run*. A server dry-run proves the API server accepts the object,
which is a long way from the behaviour being right, and in this lane three of the
failure modes report healthy while doing nothing. Do not trust any of them until a real
request has been through and the refusal has been seen.

Apply order, once agentgateway Enterprise is installed:

```
kubectl --context $EKS apply -f yaml/30-gateway.yaml
kubectl --context $EKS apply -f yaml/31-vllm-backend.yaml
kubectl --context $EKS apply -f yaml/32-jwt-policy.yaml
kubectl --context $EKS apply -f yaml/33-models-networkpolicy.yaml
kubectl --context $EKS apply -f yaml/34-uk-pii-guard.yaml
kubectl --context $EKS apply -f yaml/35-tracing.yaml
kubectl --context $EKS apply -f yaml/36-egress-lockdown.yaml
```

Set the context explicitly every time:

```
export EKS=arn:aws:eks:eu-west-2:<AWS_ACCOUNT_ID>:cluster/uk-sovereign-ai
```

This is not fussiness. Several kind clusters live in the same `~/.kube/config` and
creating one rewrites `current-context`, so a bare `kubectl apply` can land on a kind
cluster and report complete success. A PVC pending on kind looks exactly like a PVC
pending on EKS.

## Which act each file carries

| File | Act | What the audience sees |
|---|---|---|
| `30-gateway.yaml` | all | The one door |
| `31-vllm-backend.yaml` | 3 | The in-region model answers, the US API does not |
| `32-jwt-policy.yaml` | 2 | With a token, 200. Without one, 401 |
| `33-models-networkpolicy.yaml` | 2 | Direct-to-vLLM times out |
| `34-uk-pii-guard.yaml` | 4 | An NHS number is refused before inference |
| `35-tracing.yaml` | 7 | The evidence pack has rows in it |
| `36-egress-lockdown.yaml` | 3 | The US API is refused, the London model answers |

## Three things that will silently not work

Each of these applies cleanly, reports healthy, and does nothing. All three sit under
demo acts, so none of them can be verified by reading config.

**NetworkPolicy is off by default, and the command that enables it can take the CNI
down.** Two separate traps, both hit live on 2026-08-07.

The VPC CNI ships `aws-eks-nodeagent` with `--enable-network-policy=false`, so
NetworkPolicy objects apply, report healthy, and enforce nothing. Enable it on the
addon. **But pass `--service-account-role-arn` when you do:**

```
aws eks update-addon --cluster-name uk-sovereign-ai --region eu-west-2 \
  --addon-name vpc-cni \
  --service-account-role-arn <the vpc-cni addon IRSA role arn> \
  --configuration-values '{"enableNetworkPolicy":"true"}' \
  --resolve-conflicts OVERWRITE
```

Running that update *without* the role arn set the addon's `serviceAccountRoleArn` to
`null` and stripped the `eks.amazonaws.com/role-arn` annotation off the
`kube-system/aws-node` ServiceAccount. ipamd then fell back to IMDS node-instance-role
credentials, which carry `AmazonEKSWorkerNodePolicy` but not `AmazonEKS_CNI_Policy`, so
`ec2:DescribeNetworkInterfaces` returned `UnauthorizedOperation`, ipamd never finished
init, never served its socket, and `aws-eks-nodeagent` crashlooped with a Go panic about
`dial unix /var/run/aws-node/ipamd.sock: connect: connection refused`. New pods sat in
`ContainerCreating`.

Nothing in any `kubectl` output mentions IAM. It presents as a node fault, a CNI bug or
a netpol bug, and it is none of those. When the CNI misbehaves, check in this order:

```
kubectl -n kube-system get sa aws-node -o jsonpath='{.metadata.annotations}'
aws eks describe-addon --addon-name vpc-cni --query 'addon.serviceAccountRoleArn'
kubectl debug node/<node> -it --image=busybox --profile=sysadmin -- \
  sh -c 'grep -i unauthorized /host/var/log/aws-routed-eni/ipamd.log | tail'
```

`kubectl logs` on `aws-node` is nearly useless here; the real log is
`/var/log/aws-routed-eni/ipamd.log` on the node. One cheap signal from stdout does hold:
healthy ipamd prints `Checking for IPAM connectivity...` then `Copying config file...`
then `Successfully copied CNI plugin binary and config file.` A broken one stops at the
first. Compare full output rather than tails, because a healthy pod's truncated tail can
also end on that line.

Also worth knowing: while the addon sits in `UPDATING`, `update-addon` returns
`ResourceInUseException`, so you cannot roll the change back until it settles.

**Enforcement is proven working on this cluster**, once the IAM was fixed. Tested with
two busybox pods and a temporary deny-all ingress policy rather than by reading config:

| Scenario | Result |
|---|---|
| same-node, no policy | HTTP 404, connected |
| same-node, deny-all ingress | timed out, 3 of 3 attempts |
| cross-node, deny-all ingress | timed out |
| cross-node, policy deleted | HTTP 404, connected again |

Cross-node matters more than same-node, because act 2's real topology has the gateway on
a system node and vLLM on the GPU node. So `33-` and `36-` stay as NetworkPolicy.

In phase 3, **add** an Istio ambient `AuthorizationPolicy` alongside rather than instead.
Act 2's claim is "the gateway is the only door", and in a real deployment that is defence
in depth: a NetworkPolicy at L3/L4 plus an identity-based policy behind it. "Here is the
network lock, and here is the identity lock behind it, and the second one is what
survives an attacker who gets a pod into the right namespace" is a stronger act than
either layer alone. If you do add it, remember that in ambient `dry-run` and the `AUDIT`
action are silent no-ops at L4; only a real `DENY` enforces.

Whichever layer is in play, prove it with act 2's own probe rather than a config read:

```
kubectl --context $EKS run probe --rm -it --image=curlimages/curl -- \
  curl -s -m 5 http://vllm.models.svc.cluster.local:8000/v1/models
```

That has to time out. If it answers, act 2 is a door with no lock.

**Prompt guard no-ops on a groups-form backend.** `31-vllm-backend.yaml` uses
`ai.provider` singular. On the `ai.groups[]`/`providers[]` failover shape the guard
attaches, reports Accepted, appears in the config dump and enforces nothing. There is
a comment saying so in the file, because the tempting change is to add a fallback
provider and the tempting change breaks act 4 without any signal.

**The UI shows No Data until the tracing policy exists and points somewhere real.**
Confirm the collector Service name rather than trusting `35-tracing.yaml`:

```
kubectl --context $EKS -n agentgateway-system get svc | grep -i collector
```

A wrong name there fails identically to having no policy at all.

## The UK PII regexes

`scripts/test-pii-regex.py` reads the patterns out of `34-uk-pii-guard.yaml` and runs
18 specimens through them. Run it before every rehearsal:

```
python3 scripts/test-pii-regex.py
```

It reads from the YAML rather than keeping its own copy so that it tests what the
gateway is actually handed after YAML unquoting, which is the part that goes wrong.

The obvious version of both patterns is wrong in ways that would show up live. The NI
pattern from the original plan misses `JM 50 13 45 D`, which is how it is printed on
an HMRC letter, misses lowercase, wrongly accepts `O` in the second position, and
matches inside a longer token. The NHS pattern misses the hyphenated form and matches
a 10-digit run inside an 11-digit number. The shipped patterns handle all of that and
the script proves it.

Rust regex syntax only. The gateway has no lookahead or lookbehind, so do not add
any. The test script rejects them rather than letting Python quietly accept what the
gateway will not.

A passing test still does not prove the guard is attached. Send one real blocked
request through the gateway every rehearsal.

## Running cost, verified against the London price list

Section 8 of the plan doc understates this. It has gp3 and S3 at "~$20/month,
negligible" and omits the NAT gateway entirely. Real numbers for `eu-west-2`, pulled
from the pricing API on 2026-08-07:

| Item | Monthly, GPU scaled to zero |
|---|---|
| 2× `m6i.large` system nodes, $0.111/hr each | $162 |
| EKS control plane, $0.10/hr | $73 |
| `model-weights` PVC: 120 GB, 6000 IOPS, 750 MiB/s | $58 |
| NAT gateway, $0.05/hr plus $0.05/GB | $37 |
| S3 copy of the weights | ~$1 |
| **Idle floor** | **~$330** |

Plus `g6.12xlarge` at $5.841/hr whenever the GPU is up.

Two things fall out of that. The PVC's provisioned IOPS and throughput are $46 of that
$58, which is month-round money for the 750 MiB/s that only matters during a
90-second model load. And a $400-450 monthly budget only leaves 15 to 20 GPU hours
once the floor is paid, which is thin for four weeks with three rehearsals.

There are two off switches, and they are not the same one:

```
./scripts/gpu.sh down        # daily. Stops the $5.84/hr, keeps the cluster and weights.
./scripts/teardown.sh down   # between build sessions. Takes the floor to about $1.
```

**Do not tear down with a bare `eksctl delete cluster`.** `yaml/00-storage.yaml` sets
`reclaimPolicy: Retain`, which is right while the cluster is alive (a spot reclaim or an
accidental PVC delete must not destroy 48 GB of weights) but means cluster deletion
leaves the EBS volume behind as an orphan that nothing references. 120 GB of gp3 at
6000 IOPS and 750 MiB/s is about **$58/month, forever**, and $46 of that is the
provisioned IOPS and throughput. "I deleted the cluster" is not "I stopped paying".

`scripts/teardown.sh` handles it:

```
./scripts/teardown.sh check      # read-only: what exists, what it costs, what will orphan
./scripts/teardown.sh down       # delete the cluster AND the orphaned volume
./scripts/teardown.sh leftovers  # what survived
```

`down` refuses to run until it has confirmed the weights are in S3 and total at least
48 GB across the expected objects. That check is the entire safety argument for deleting
the volume: S3 in `eu-west-2` is the master copy, the PVC is a cache, and
`yaml/39-model-restore-job.yaml` rebuilds the cache. If the mirror is incomplete it
stops rather than destroying the only copy.

### Rebuilding

Every line of this order matters, and four of them are counter-intuitive. The reasons are
inline because an earlier version of this list had all four wrong and each one stalls a
rebuild in a way that gives you no useful error.

```
export EKS=arn:aws:eks:eu-west-2:<AWS_ACCOUNT_ID>:cluster/uk-sovereign-ai
eksctl create cluster -f eks/cluster.yaml                    # ~20 min

# Look the role up, never paste a remembered ARN. eksctl mints this role fresh on every
# cluster create with a new random suffix, so yesterday's ARN belongs to a deleted
# cluster. Pointing the addon at a stale role is exactly how the CNI outage happened.
ROLE=$(aws eks describe-addon --region eu-west-2 --cluster-name uk-sovereign-ai \
  --addon-name vpc-cni --query 'addon.serviceAccountRoleArn' --output text)
[ -n "$ROLE" ] && [ "$ROLE" != "None" ] || { echo "no vpc-cni role, STOP"; exit 1; }
aws eks update-addon --region eu-west-2 --cluster-name uk-sovereign-ai \
  --addon-name vpc-cni --service-account-role-arn "$ROLE" \
  --configuration-values '{"enableNetworkPolicy":"true"}' --resolve-conflicts OVERWRITE

# 00-storage.yaml BEFORE the service account, because it is what creates the models
# namespace and eksctl cannot put a ServiceAccount in a namespace that does not exist.
kubectl --context $EKS apply -f yaml/00-storage.yaml

# model-restore, NOT model-sync. 39- names model-restore, and model-sync is the
# write-capable identity for a fresh Hugging Face pull, which a rebuild does not do.
eksctl create iamserviceaccount --cluster uk-sovereign-ai --region eu-west-2 \
  --namespace models --name model-restore \
  --attach-policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/uk-sovereign-ai-model-s3-readonly \
  --approve

# The GPU node BEFORE the restore, which reads backwards but is required twice over:
# 39- has nodeSelector role=gpu, and gp3-fast is WaitForFirstConsumer so the PVC cannot
# even bind until a node exists in the right AZ. Skip this and the Job sits Pending with
# nothing in its events that points at the cause.
./scripts/gpu.sh up

kubectl --context $EKS apply -f yaml/39-model-restore-job.yaml   # S3 to PVC, in-region
./scripts/keycloak.sh up && ./scripts/keycloak.sh check
./scripts/gpu-backstop.sh arm          # cannot be armed before the nodegroup exists
```

The restore reads from S3 in London, so a rebuild never touches Hugging Face. The mirror
was built for the sovereignty story and turned out to be the operational safety net too.

`aws-ebs-csi-driver` needs no manual step on a clean create: it is in `eks/cluster.yaml`
under `addons` with `wellKnownPolicies.ebsCSIController`. It only had to be installed by
hand the first time because that create aborted at the `gpu-spot` AZ error before
reaching it.

Budget roughly 40 minutes, and note the rebuild is not free: the 48 GB S3 to PVC copy and
the vLLM load both happen with the GPU node up at $5.84/hr.

### The nightly backstop

`scripts/gpu-backstop.sh` forces the GPU nodegroup to `desired=0` at 21:00 UTC daily via
EventBridge Scheduler, calling `eks:UpdateNodegroupConfig` directly. No Lambda, and the
IAM is one action scoped to one nodegroup. Arm it after a rebuild, because it cannot be
armed while the nodegroup does not exist.

**It is also a loaded gun pointed at the demo.** If it fires during a late rehearsal or
mid-webinar it pulls the GPU out from under a live audience, and nothing about
EventBridge cares that you are on camera. So:

```
./scripts/gpu-backstop.sh disarm    # FIRST LINE of the webinar-day pre-flight checklist
./scripts/gpu-backstop.sh arm       # after the webinar
```

It scales rather than deleting, so a forced scale-down costs an 8 minute `gpu.sh up`, not
a re-pull. `maxSize` stays 1 so `gpu.sh up` works the next morning with no edit.

## Open items

**Keycloak is done and running.** Lifted from
`agentgateway-quickstart-kind/yaml/keycloak/` rather than written fresh, adapted to
realm `sovereign`. `yaml/37-keycloak.yaml` plus `yaml/37-keycloak-realm.json`, deployed
by `scripts/keycloak.sh up`.

```
./scripts/keycloak.sh up          # deploy, imports the realm
./scripts/keycloak.sh check       # prove iss and aud match yaml/32-jwt-policy.yaml
./scripts/keycloak.sh claims bob  # decoded token
```

Users `alice` / `bob` / `carol`, passwords the same as the usernames, on groups
`platform` / `research` / `admin`. Client `sovereign-ai`, public, direct access grants,
so a token is a password grant over a short-lived port-forward. Keycloak is not exposed
publicly and will not be, which suits the story: the IdP is in the UK and unreachable
from outside the cluster.

Validated live on 2026-08-07, all three users:

```
token iss:     http://keycloak.keycloak.svc.cluster.local/realms/sovereign
policy issuer: http://keycloak.keycloak.svc.cluster.local/realms/sovereign
MATCH. token aud: sovereign-ai
```

Two details worth not undoing. There is **no port in the issuer**, because `KC_HOSTNAME`
is pinned to `http://keycloak.keycloak.svc.cluster.local` and the Service listens on 80.
An earlier version of `32-jwt-policy.yaml` had `:8080` and it was wrong. That pin is
what makes the `iss` claim identical whether a token was minted through a port-forward
or from inside the cluster; without it, a token minted on `localhost:18080` carries
`iss=http://localhost:18080/...` and every request 401s in a way that looks exactly like
a missing token. Run `./scripts/keycloak.sh check` before every rehearsal rather than
reading the two strings and assuming.

And each user carries a **singular `group` claim** from a user attribute as well as the
usual `groups` array. The shipped budget dimension expression is
`coalesce(jwt.group, apiKey.group)`, singular, so cost attribution works against the
chart default and nobody has to override `budgetDimensions` and lose the other
dimensions with it.

**What the cost UI shows for a self-hosted model is unresolved.** The built-in catalog
prices known hosted models, and `mistral-small-3.2-24b` running on your own GPU is not
one of them. I could not confirm the field for this from the knowledge base: the
gateway chart has no pricing key (`agentgatewayModels` is the experimental model API,
not a price list), and the management chart's values are not in the KB, so I am not
going to guess a field name into this file. Resolve it against the real chart:

```
helm show values <management-chart> | grep -iE 'cost|price|catalog'
```

Decide what act 7 and the cost slide should say before you configure anything. The
honest number is the node, not a per-token price: `g6.12xlarge` on-demand at
$5.84/hr in `eu-west-2a`.

Do not quote a spot price. Spot is not viable for 4-GPU nodes in London: EKS returns
`UnfulfillableCapacity` and spot placement scores are 1/10 for both `g6.12xlarge` and
`g5.12xlarge` across all three AZs. The node is on-demand `g6.12xlarge`, nodegroup
`gpu-od`, single AZ `eu-west-2a`, desired 0 by default. Budget roughly $400 to $450
for a month of build, not the $150 a spot price would suggest.

Capacity in London is visibly tight, and `g5.12xlarge` is currently not obtainable
there at all. A capacity reservation ahead of the webinar is close to essential rather
than nice to have. That is Tom's call.

Separately, if you add budget dimensions, note that `budgetDimensions` in Helm
replaces the defaults rather than adding to them. Copy the shipped `group`, `user`
and `virtualKey` entries into your override or you will lose them.

**`39-model-restore-job.yaml` needs a read-only service account that does not exist
yet.** The exact IAM policy and `eksctl create iamserviceaccount` commands are in the
file header. Read-only on purpose: the recovery path has no business being able to
overwrite the master copy of the weights.

This Job is the recovery path, deliberately not an init container on vLLM. An S3
check on every pod start would add a failure mode to the component most likely to be
restarting live on camera, and buys nothing during the demo. It refuses to run if the
weights are already present, and it verifies `consolidated.safetensors`,
`params.json` and `tekken.json` before declaring success, because missing any one of
them fails at model load several minutes in with an error that does not point at a
missing file.
