# istio-ambient-multiregion-eks

**Two EKS regions, one peered Solo ambient mesh. Automatic regional failover at the mesh layer (global service, locality-preferred) and the edge layer (kgateway + AWS Global Accelerator). No management plane in the data path.**

Built to answer three multi-region questions from a real customer PoC:

1. **Automated regional failover** — traffic to a service in `eu-central-1` re-routes to `eu-west-1` when local pods are unhealthy or the region is unreachable.
2. **Locality-weighted routing** — the mesh prefers the closest healthy region (and why there is no latency probe).
3. **Scale (1000 tenants)** — what actually scales when there is no management plane in the discovery path.

- **Edition:** Enterprise (Solo Istio Helm charts, multicluster peering needs a Solo licence).
- **Cloud:** AWS, two regions (`eu-central-1`, `eu-west-1`). **Billed infrastructure** — run `teardown.sh` when done.
- **Validated live on:** Solo Istio `1.29.3-solo`, kgateway `v2.2.0`, AWS Global Accelerator + Route53 health checks, EKS `1.33`.

## Never run this against the wrong AWS account

`secrets-envs.sh` exports `AWS_PROFILE` as a side effect. To stop that silently choosing the account, every
AWS-touching script requires `LAB_AWS_PROFILE` set **explicitly** and overrides `AWS_PROFILE` with it:

```bash
export LAB_AWS_PROFILE=<your-sandbox-aws-profile>
```

## The two regions

| Cluster | Region | Role |
|---|---|---|
| `mesh-eu-central` | `eu-central-1` | region A |
| `mesh-eu-west` | `eu-west-1` | region B |

Change them with `REGION1`/`REGION2`/`NAME1`/`NAME2` env vars (see `scripts/lib.sh`).

## Run it

```bash
# 0. two clusters (~15 min each, run in parallel)
eksctl create cluster -f eksctl/mesh-eu-central.yaml
eksctl create cluster -f eksctl/mesh-eu-west.yaml

export LAB_AWS_PROFILE=<your-aws-profile>
export SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh   # SOLO_ISTIO_LICENSE_KEY

# 1. mesh + peering + app
./scripts/01-istio.sh          # Solo ambient on both, plain Helm, shared root CA
./scripts/02-peering.sh        # east-west NLBs + istiod peering + remote secrets
./scripts/03-app.sh            # region-echo as a global service in both regions

# 2. the demos
./scripts/04-demo-pod-failover.sh                 # DEMO 1  — mesh-layer failover

# ── Edge failover, two independent approaches (pick one; both shown) ──
./scripts/05-ingress-ga.sh                        # kgateway ingress per region + Global Accelerator
./scripts/07-demo-region-failover.sh <ga-dns>     # DEMO 2B — edge failover via Global Accelerator (anycast)

HOSTED_ZONE_ID=<zone> RECORD_NAME=region-echo.<domain> ./scripts/08-dns-route53.sh
./scripts/09-demo-dns-failover.sh region-echo.<domain>   # DEMO 2A — edge failover via Route 53 (DNS)

./scripts/06-scale.sh 100                         # DEMO 3  — scale ramp

# 3. tear it ALL down (billed infra)
HOSTED_ZONE_ID=<zone> RECORD_NAME=region-echo.<domain> ./scripts/teardown.sh   # deletes the DNS record set too
```

## What each demo proves

1. **Mesh failover (`04`).** Client calls the same hostname throughout. Scale `region-echo` to 0 in one region → responses come from the other region over the east-west gateway → scale back → local again. Deterministic locality, no health-check config, cross-region bytes only during the outage.
2. **Edge failover — two approaches, both live.**
   - **Global Accelerator (`05` + `07`)** — anycast static IPs over both regional NLBs. Kill the ingress in the region GA is serving this client → GA fails it out and serves the other in ~40s → restore. No DNS, no TTLs.
   - **Route 53 DNS (`08` + `09`)** — a failover record set (PRIMARY eu-central, SECONDARY eu-west), each tied to a health check. Kill the primary ingress → the record hands out the secondary NLB on the next resolution. Needs a hosted zone; cutover is health-check + record TTL + client caching.
3. **Scale (`06`).** Ramp N tenant namespaces (global services) on both clusters; capture istiod push metrics, ztunnel memory, and time-to-discovery of a new global service from the peer. There is no management plane in this path — istiod per cluster is the thing that scales.

## Gotchas found live (all fixed in the scripts)

- **Plain Helm has no `istio-eastwest` GatewayClass** (the Gloo Operator ships it). Create it manually and set `AMBIENT_ENABLE_MULTI_NETWORK=true` on istiod, or the east-west gateway never programs. (`01`)
- **NLBs give DNS names, not IPs** — the remote peer reference needs `addressType: Hostname`. (`02`)
- **kgateway needs the experimental `TLSRoute` CRD**, which the Gateway API standard-install omits; eksctl clusters also carry a `safe-upgrades` ValidatingAdmissionPolicy that blocks experimental CRDs. Remove the VAP, apply the CRD. (`05`)
- **kgateway's `gateway.kgateway.dev/service-annotations` does not propagate** in v2.2.0 — use the standard `spec.infrastructure.annotations` to make the ingress an NLB. (`05`)
- **Global Accelerator inherits the NLB's target-group health.** With `externalTrafficPolicy: Cluster` (default) the NLB health check passes on every node even with zero ingress pods, so GA never fails over. Set `externalTrafficPolicy: Local`. (`05`)
- **Locality preference is the Service `spec.trafficDistribution` FIELD**, not the `networking.istio.io/traffic-distribution` annotation, which is ignored on this line. (`03`)

## Which layer for which failure

| Failure | Layer | Mechanism | Cutover |
|---|---|---|---|
| Local pods unhealthy | Mesh (ztunnel) | Global service, Failover LB | seconds |
| Region edge unreachable | Edge (Global Accelerator) | Anycast IPs + health check | ~20–40s, no DNS |
| Prefer closest region | Mesh (ztunnel) | Topology-deterministic | no latency probe |
| Latency-based steering | Client (Route53 / GA) | Route53 latency / GA proximity | DNS TTL (Route53) |
| 1000 tenants discovery | istiod peering | Direct istiod↔istiod | per-cluster istiod |
