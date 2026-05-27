# `quick.sh` — Enterprise AgentGateway multicluster standup on kind

End-to-end platform setup for the
[agentgw-multi-cluster-kind](https://www.masterthemesh.com/solo/agentgw-multi-cluster-kind/)
lab. Stands up two ambient kind clusters (`east-ag`, `west-ag`) peered over
HBONE, installs Solo Istio Ambient via Gloo Operator + `ServiceMeshController`,
and installs Solo Enterprise agentgateway as the north-south ingress controller.
Platform-only — workloads are deployed by the follow-on labs
([cloud-connectivity](https://www.masterthemesh.com/solo/agentgw-cloud-connectivity/),
[agentic-mcp](https://www.masterthemesh.com/solo/agentgw-agentic-mcp/)).

## Usage

```bash
# Default install — agentgateway v2.3.3 from the public Solo registry
./scripts/quick.sh

# Verified-fixed nightly that resolves the cross-cluster failover gap
AGW_NIGHTLY=true ./scripts/quick.sh

# Teardown both clusters + certs/
./scripts/quick.sh teardown
```

## Prerequisites

| Tool                         | Why                                                                  |
|------------------------------|----------------------------------------------------------------------|
| Docker Desktop ≥ 8 CPU / 16 GB | Hosts the two kind clusters + their nodes (control-plane + worker) |
| `kind`                       | Cluster orchestrator                                                 |
| `kubectl` + `helm`           | Operate the clusters                                                 |
| `istioctl` (Solo build)      | `multicluster check`, `ztunnel-config service`                       |
| `openssl`                    | Generates the shared root CA + per-cluster intermediates             |
| `gcloud` (authenticated)     | `gcloud auth configure-docker us-docker.pkg.dev` so the Solo Istio images can be pulled |

### Licences (required)

Either export these directly or point `SECRETS_FILE` at a sourceable shell script
that exports them. The script exits early with a clear error if they're missing.

```bash
export SOLO_ISTIO_LICENSE_KEY="eyJ..."   # required for Solo Istio multicluster
export AGENTGATEWAY_LICENSE_KEY="eyJ..." # required for agentgateway control plane
export GLOO_MESH_LICENSE_KEY="eyJ..."    # optional — only if you run the Gloo UI step
# Or:
export SECRETS_FILE=/path/to/secrets-envs.sh   # script defaults to /Users/.../code/solo/secrets/secrets-envs.sh
```

The Solo Istio licence JWT must have `"lt": "ent"` for the multicluster feature
gate to unlock; a trial JWT (`"lt": "trial"`, `"product": "gloo-trial"`) lets
peering connect but won't enable global service rewriting.

## What it builds

1. Two kind clusters (`east-ag` / `west-ag`) on a shared Docker bridge.
2. MetalLB with non-overlapping pools (east `.100-.110`, west `.120-.130`).
3. Shared root CA + per-cluster intermediates, all with SAN
   `spiffe://cluster.local/ns/istio-system/sa/citadel` (cert chain validation
   requires the trust domain to match the runtime trust domain, which the EAG
   waypoint binary hardcodes to `cluster.local`).
4. Gateway API CRDs v1.4.0 (v1.5.0 ships a `safe-upgrades`
   ValidatingAdmissionPolicy that blocks the SMC reconciler).
5. Solo Istio Ambient 1.29.2 via Gloo Operator 0.5.2 + `ServiceMeshController`.
6. `SOLO_LICENSE_KEY` env wired onto `istiod-gloo` via `secretKeyRef` →
   `solo-istio-license` Secret in `istio-system`. `pilot-discovery` only reads
   this env var (not `LICENSE_KEY` / `GLOO_LICENSE_KEY` / mount paths) — without
   it the multicluster feature gate stays closed.
7. `PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false` on `istiod-gloo` +
   `L7_ENABLED=true` on `ztunnel` (required for Ambient peering, not exposed by
   the SMC schema today).
8. East-west HBONE gateways via Solo Istio's `peering` helm chart, type
   LoadBalancer (MetalLB IPs).
9. Per-cluster `Gateway` + `RemoteGateway` peer references.
10. Cross-applied `istio-remote-secret-*` Secrets (token bound to
    `istio-reader-service-account`).
11. Solo Enterprise agentgateway control plane + CRDs at the version selected
    by `AGW_VERSION` / `AGW_REGISTRY` / `AGW_NIGHTLY`.
12. Smoke test — `istiod-gloo` Available, `ztunnel` Ready on every node,
    east-west GW has an LB IP, peering verified.

## Configuration via env vars

| Var                  | Default                                                                                   | Purpose                                                                                                  |
|----------------------|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `CLUSTER1` / `CLUSTER2` | `kind-east-ag` / `kind-west-ag`                                                       | kube-contexts. The `-ag` suffix means this lab can run alongside the `istio-gw-multi-cluster-kind` lab.  |
| `SECRETS_FILE`       | `/Users/tomorourke/code/solo/secrets/secrets-envs.sh`                                     | Sourced before the licence-env check.                                                                    |
| `SOLO_ISTIO_VERSION` | `1.29.2-solo`                                                                             | Solo Istio image tag. SMC's `.spec.version` is derived as `${SOLO_ISTIO_VERSION%-solo}`.                 |
| `GLOO_OPERATOR_VERSION` | `0.5.2`                                                                                | Helm chart version for the Gloo Operator.                                                                |
| `GATEWAY_API_VERSION`| `v1.4.0`                                                                                  | Standard Gateway API release. **Stay on 1.4.x** — 1.5.0 ships a `safe-upgrades` admission policy that blocks SMC's bundled CRD apply. |
| `AGW_VERSION`        | `v2.3.3`                                                                                  | Enterprise agentgateway chart tag (v-prefixed at 2.2+).                                                  |
| `AGW_REGISTRY`       | `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts`                      | OCI helm repo. Override to test pre-release or air-gapped builds.                                        |
| `AGW_IMAGE_REGISTRY` | *(empty)*                                                                                 | When set, the script pre-pulls the controller + dataplane images on the host and `docker save | ctr import`s them into both kind clusters — required for any registry the kind nodes can't anonymously pull from. |
| `AGW_NIGHTLY`        | `false`                                                                                   | When `true`, overrides the three vars above to install the verified-fixed nightly (see next section).    |
| `METALLB_VERSION`    | `v0.14.9`                                                                                 | MetalLB chart version.                                                                                   |
| `GLOO_MESH_VERSION`  | `2.12.0`                                                                                  | Optional Gloo Mesh management plane (only installed if `GLOO_MESH_LICENSE_KEY` is set).                  |

## `AGW_NIGHTLY=true` — verified-fixed nightly

The released `v2.3.3` agentgateway dataplane NACKs istiod's synthetic
cross-cluster `WorkloadEntry` as `"unknown address type"`. Cross-cluster ingress
failover via the agentgateway returns HTTP 503 when local backends scale to 0.

The fix is in the nightly. Empirically verified on this lab's exact topology:
the failover test (Cloud Connectivity LAB 1) returns **HTTP 200 across 3/3
attempts** with the nightly installed instead, and the NACK is gone from the
proxy xDS logs.

```
┌────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│      Setting       │                                          When AGW_NIGHTLY=true                                           │
├────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ AGW_VERSION        │ v2026.5.0-beta.4-nightly-2026-05-15                                                                      │
├────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ AGW_REGISTRY       │ oci://us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev/charts                    │
├────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ AGW_IMAGE_REGISTRY │ us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev (triggers pre-pull + kind load) │
└────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

```bash
AGW_NIGHTLY=true ./scripts/quick.sh
```

Anyone with the standup already up can swap the build in place — see the
[Appendix](https://www.masterthemesh.com/solo/agentgw-multi-cluster-kind/#appendix)
on the lab page for the manual commands.

## Idempotency

The script is fully idempotent — re-run as many times as you like. Image pulls
are cached, kind clusters are skipped if they already exist, helm releases use
`upgrade --install`, and env-var patches are guarded with an existence check
before being added (so duplicates aren't appended on re-runs). The slowest
step on a re-run is `helm --wait` on the agentgateway control plane and the
SMC reconciler picking up any changes.

## Teardown

```bash
./scripts/quick.sh teardown
```

Deletes both kind clusters and the local `certs/` directory. The Docker bridge
remains (kind reuses it on the next run).

## Troubleshooting

| Symptom                                                              | Cause + fix                                                                                                     |
|----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| `Error from server (NotFound): deployments.apps "istiod-gloo" not found` | `wait_deploy` ran before the SMC reconciler created the Deployment. The helper now polls for existence first — this should not happen on the current script. If it does, re-run; the resource will exist on the second attempt. |
| `Installing CRDs with version before v1.5.0 is prohibited`           | Gateway API v1.5.0 leaked onto the cluster. Stay on v1.4.0 (the default), or delete the `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy + binding before SMC reconciles. |
| `License Check: found invalid license for multicluster` (istioctl)    | The Solo Istio licence JWT is `"lt": "trial"` (or another non-`ent` tier). Multicluster needs `"lt": "ent"` — request from your Solo contact. |
| `Failed to pull image ... 403 Forbidden` on the agentgateway pod      | The chart is on a private registry. Set `AGW_IMAGE_REGISTRY` (or use `AGW_NIGHTLY=true`) so the script pre-pulls + side-loads the images into the kind nodes. |
| `BASELINE: HTTP 503` on cross-cluster failover                       | Agentgateway dataplane NACK on synthetic `WorkloadEntry`. Install the nightly (`AGW_NIGHTLY=true`) or use the parallel `istio` Gateway pattern (see `yaml/side-by-side/istio-gateway.yaml`). |

## Layout

```
agentgw-multi-cluster-kind/
├── kind/                 # kind cluster configs (east-ag, west-ag — disjoint subnets)
├── scripts/
│   ├── 00-prereqs.sh     # one-shot prereq check (used by quick.sh too)
│   ├── 01-clusters.sh    # kind create
│   ├── 02-metallb.sh     # MetalLB install + IP pool config
│   ├── 03-istio.sh       # Gloo Operator + SMC + cert wiring + env patches
│   ├── 04-agentgateway.sh # agentgateway CRDs + control plane
│   ├── 05-demo-workloads.sh # optional demo bookinfo/echo-mcp (used by follow-on labs)
│   ├── k9s-tabs.sh       # macOS — open k9s in two Terminal tabs
│   └── quick.sh          # end-to-end orchestrator (this file's subject)
└── yaml/                 # all Gateway / HTTPRoute / Policy YAML the labs apply
    └── side-by-side/
        └── istio-gateway.yaml  # parallel istio Gateway for the workaround pattern
```
