<a id="quick-singlesh--solo-istio-ambient-single-cluster-standup-on-kind"></a>
# `quick-single.sh`: Solo Istio Ambient single-cluster standup on kind

Companion to [`quick.sh`](./quick.sh) for the **cross-host peering** demo:
stand up `east` on one machine (e.g. a laptop), `west` on a second machine
(e.g. a mac mini), then peer the two clusters across the real LAN. Each
machine runs `quick-single.sh` once.

`quick.sh` is the right choice when both clusters live on one host: it does
the full peering (east-west gateways + `multicluster link`) for you in one
invocation.
`quick-single.sh` is the right choice when each half lives on a different
host, because the cross-cluster steps need to be deferred until after both
machines are up.

This is the **Solo Istio Gateway** flavour of the standup. The
[`agentgw-multi-cluster-kind`](../../agentgw-multi-cluster-kind/scripts/)
repo has the matching `quick-single.sh` for the **Enterprise agentgateway**
flavour: pick whichever north-south ingress you want to demo. The Solo
Istio + Ambient platform underneath is identical.

## Usage

```bash
# Stand up — cluster name is FREE-FORM (any valid Kubernetes DNS label).
# The same name is used as the kind cluster name, kube context (kind-<name>),
# the `topology.istio.io/network` label, and the SMC `cluster:`/`network:` fields.
./scripts/quick-single.sh <cluster-name>

# Teardown (delete kind cluster + remove certs/)
./scripts/quick-single.sh teardown <cluster-name>

# Examples
./scripts/quick-single.sh east-laptop
./scripts/quick-single.sh west-mini
./scripts/quick-single.sh green
./scripts/quick-single.sh blue
```

The script validates the name against the k8s DNS-label regex
(`^[a-z][a-z0-9-]*[a-z0-9]$`) and refuses to run otherwise.

> [!IMPORTANT]
> The two machines must use **different** cluster names. Calling both halves
> `green` will collide in istiod's cluster registry once peered.

## End-to-end flow across two machines

```text
┌─────────────────────────────┐         ┌─────────────────────────────┐
│  Machine A (e.g. laptop)    │         │  Machine B (e.g. mac mini)  │
│                             │         │                             │
│ 1. quick-single.sh east     │         │                             │
│    └─ generates root CA     │   scp   │                             │
│    └─ emits peer-bundle ────┼────────►│ 2. drop bundle's root-ca.*  │
│                             │         │    into certs/              │
│                             │         │ 3. quick-single.sh west     │
│                             │   scp   │    └─ reuses shared root CA │
│ 5. apply peer bundle  ◄─────┼─────────┼─ 4. emits its peer-bundle    │
│                             │         │                             │
│                             │         │ 6. apply peer bundle from A │
└─────────────────────────────┘         └─────────────────────────────┘
```

The script prints copy-paste `kubectl apply` commands at the end of each run:
you don't need to memorise the flow.

## Prerequisites

| Tool                            | Why                                                                  |
|---------------------------------|----------------------------------------------------------------------|
| Docker Desktop ≥ 8 CPU / 16 GB  | Hosts the kind cluster (control-plane + worker)                      |
| `kind`                          | Cluster orchestrator                                                 |
| `kubectl` + `helm`              | Operate the cluster                                                  |
| `istioctl` (Solo build)         | `multicluster expose` (creates the east-west GW), `multicluster check` |
| `openssl`                       | Generates the shared root CA + per-cluster intermediate              |
| `gcloud` (authenticated)        | `gcloud auth configure-docker us-docker.pkg.dev` so the Solo Istio images can be pulled |

### Licence (required)

```bash
export SOLO_ISTIO_LICENSE_KEY="eyJ..."   # Solo Istio multicluster (lt: ent)
# Or:
export SECRETS_FILE=/path/to/secrets-envs.sh
```

`SECRETS_FILE` defaults to `/Users/tomorourke/code/solo/secrets/secrets-envs.sh`
(matching `quick.sh`). Override or unset for the second machine.

The Solo Istio licence JWT must have `"lt": "ent"` for the multicluster
feature gate to unlock; a trial JWT (`"lt": "trial"`) lets peering connect
but won't enable global service rewriting.

### Same root CA on both machines

Cross-cluster mTLS requires the two intermediates to chain back to the same
root. The script handles this automatically:

* **First machine:** generates a fresh `certs/root-ca.crt` + `certs/root-ca.key`.
  The peering bundle written at the end includes a copy of both, so you can
  ship them to machine B.
* **Second machine:** if you drop the shared `root-ca.{crt,key}` into `certs/`
  **before** running the script, it reuses them and generates only the local
  intermediate. If `certs/root-ca.crt` already exists, the script silently
  reuses it without prompting.

A yellow `NOTE` is printed up front when no root CA is found locally: read it
before proceeding on the second machine.

## What it builds (per machine)

1. One kind cluster (`kind-<name>`, control-plane + worker), with pod
   `10.10.0.0/16` and service `10.96.0.0/16`. **No CIDR partitioning** between
   machines is needed: each Docker bridge is independent, and cross-cluster
   traffic egresses via the east-west GW's external LB IP (HBONE), never
   pod-IP to pod-IP.
2. MetalLB pool `<bridge-base>.255.200-.210` on the local Docker bridge.
3. Shared root CA (generated or reused) + this cluster's intermediate, SAN
   `spiffe://cluster.local/ns/istio-system/sa/citadel`, applied as `cacerts`
   in `istio-system`.
4. Gateway API CRDs v1.4.0.
5. Solo Istio Ambient via Gloo Operator + `ServiceMeshController`
   (`cluster: <name>`, `network: <name>`, `trustDomain: cluster.local`).
6. `SOLO_LICENSE_KEY` env wired onto `istiod-gloo` via `secretKeyRef`.
7. `PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false` on `istiod-gloo` +
   `L7_ENABLED=true` on `ztunnel`.
8. East-west gateway via `istioctl multicluster expose -n istio-gateways`
   (LoadBalancer, MetalLB IP). Its **address** is what goes into the peering
   bundle below; that address is all a peer needs, on `:15008` for HBONE and
   `:15012` for the istiod-to-istiod xDS connection.
9. `topology.istio.io/network=<name>` on `istio-system`.
10. Smoke test: `istiod-gloo` Available, `ztunnel` fully scheduled,
    east-west GW has an LB IP.
11. **Peering bundle** at `certs/peer-bundle-<name>.tar.gz` (see next section).

## The peering bundle

At the end of each run the script writes `certs/peer-bundle-<name>.tar.gz`
containing:

| File                                 | Purpose                                                                                        |
|--------------------------------------|------------------------------------------------------------------------------------------------|
| `eastwest-ip.txt`                    | This cluster's east-west GW external LB IP. **This is the whole contract.** The peer writes an `istio-remote` Gateway pointing at it, and both the data plane (`:15008` HBONE) and the peer's istiod (`:15012` xDS) use that one address. |
| `cluster-name.txt`                   | This cluster's name (also used as the `network`).                                              |
| `root-ca.crt` + `root-ca.key`        | Shared root CA so the second machine's intermediate chains back to the same root.              |

Ship `peer-bundle-<name>.tar.gz` to the other machine. The script's summary
prints the exact `scp` + `peer-with.sh` commands you'll need on the receiving
side. Note what the bundle does **not** contain: any credential for this
cluster. There is no remote secret and no kubeconfig, because peering in the
Solo distribution never reaches the peer's Kubernetes API. Discovery rides the
istiod-to-istiod xDS connection to the east-west gateway, so **one
`istio-remote` peer Gateway per direction** is all the peering needs.

## Configuration via env vars

| Var                     | Default                          | Purpose                                                                              |
|-------------------------|----------------------------------|--------------------------------------------------------------------------------------|
| `SECRETS_FILE`          | `/Users/tomorourke/code/solo/secrets/secrets-envs.sh` | Sourced before the licence-env check.                            |
| `SOLO_ISTIO_VERSION`    | `1.29.2-solo`                    | Solo Istio image tag. SMC's `.spec.version` is `${SOLO_ISTIO_VERSION%-solo}`.        |
| `GLOO_OPERATOR_VERSION` | `0.5.2`                          | Helm chart version for the Gloo Operator.                                            |
| `GATEWAY_API_VERSION`   | `v1.4.0`                         | Stay on 1.4.x: v1.5.0 ships a `safe-upgrades` admission policy that blocks SMC's CRD apply. |
| `METALLB_VERSION`       | `v0.14.9`                        | MetalLB chart version.                                                               |

<a id="networking-caveat--kind--macos--cross-host"></a>
## Networking caveat: kind + macOS + cross-host

> [!WARNING]
> The east-west GW LB IP that the script assigns lives on the local Docker
> bridge (e.g. `172.18.255.200`). That address is **not routable from another
> physical host** by default — the second machine's istiod-gloo will time
> out trying to dial it on TCP 15008 + 15012 + 15021.

To run a real cross-host demo on macOS, you'll need to publish the east-west
GW on each host's LAN-reachable address. Common patterns:

* **`ssh -L` / `ssh -R` tunnels** for the gateway ports: fine for a one-shot
  demo.
* **`socat`** on each host forwarding `<lan-ip>:<port> → <bridge-ip>:<port>`.
* **Tailscale / WireGuard** for routable overlay between hosts.
* **Linux hosts** instead of macOS: the kind bridge is reachable from the
  LAN with a single host-level static route, so no tunnels needed.

You do **not** need this cluster's kube API server reachable from the peer.
That is the one thing peering removes: the two control planes federate over
mTLS xDS through the east-west gateway, so istiod never watches the remote
Kubernetes API and no kubeconfig crosses the wire. Set
`DISABLE_LEGACY_MULTICLUSTER=true` on istiod and it will not even look at a
remote secret.

What does need LAN reachability is the address in `eastwest-ip.txt`, on
**`:15008`** (HBONE data plane) and **`:15012`** (xDS control plane). Those two
ports between the two hosts are the entire cross-host requirement.

## Idempotency

Re-running `./scripts/quick-single.sh <same-name>` is a no-op end-state:
image pulls cache, kind cluster is skipped if it already exists, helm
releases use `upgrade --install`, env-var patches are guarded with an
existence check before being added, and the peering bundle is rewritten so
it always reflects the current east-west IP.

## Teardown

```bash
./scripts/quick-single.sh teardown <cluster-name>
```

Deletes the kind cluster and removes the entire `certs/` directory. If you're
tearing down only one machine in the peering, the other side will keep a
stale `istio-remote` peer Gateway pointing at a dead cluster: clean it up on
the surviving machine with:

```bash
kubectl --context kind-<surviving> -n istio-gateways \
  delete gateway istio-remote-peer-<gone-cluster>
```

## Troubleshooting

| Symptom                                                              | Cause + fix                                                                                                     |
|----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| `ERROR: '<name>' is not a valid cluster name`                        | Cluster name must match `^[a-z][a-z0-9-]*[a-z0-9]$` (k8s DNS label).                                            |
| `Installing CRDs with version before v1.5.0 is prohibited`           | Gateway API v1.5.0 leaked onto the cluster. Stay on v1.4.0 (the default), or delete the `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy before SMC reconciles. |
| `License Check: found invalid license for multicluster` (istioctl)   | Solo Istio licence JWT is `"lt": "trial"`. Multicluster needs `"lt": "ent"`: request from your Solo contact.   |
| Cross-host peering never converges (`istioctl multicluster check` fails on peers) | Peer's istiod can't reach this cluster's east-west GW on **15012**, so the xDS connection the two control planes federate over never establishes. Check the LAN publish and the peer Gateway's address: see [Networking caveat](#networking-caveat--kind--macos--cross-host). Nothing here involves the kube API. |
| `istioctl multicluster check` shows clusters connected but pod-to-pod returns 503 | Peer's ztunnel can't reach this cluster's east-west GW on **15008**. Verify the LB IP is published on a routable LAN address and that the peer Gateway (or your tunnel) points at it. |

<a id="cross-host-helpers--expose-ew-on-hostsh--peer-withsh"></a>
## Cross-host helpers: `expose-ew-on-host.sh` + `peer-with.sh`

The networking caveat above (Docker-bridge east-west IP not routable from
another host) has two parts: (1) publish the east-west GW on a LAN-reachable
address, and (2) point the peer's `istio-remote` Gateway at it, which covers
both its istiod (`:15012`) and its data plane (`:15008`). Two helpers automate
both halves of that.

### `scripts/expose-ew-on-host.sh`

Republishes the east-west GW's HBONE (15008) + XDS (15012) + status (15021)
ports on this host's LAN IP by launching `alpine/socat` Docker containers on
the `kind` network. The containers can dial the MetalLB LB IP (they're on
the same Docker bridge as the kind nodes), and Docker's
`-p <HOST_LAN_IP>:port:port` flag binds the listener to the Mac's LAN
interface so the peer machine can reach it.

```bash
# Start tunnels (auto-detects LAN IP via ipconfig getifaddr en0/en1, falls
# back to en1; on Linux uses `hostname -I`).
./scripts/expose-ew-on-host.sh <cluster-name>

# Override the host LAN IP (e.g. when running on a Tailscale interface):
HOST_LAN_IP=100.64.0.5 ./scripts/expose-ew-on-host.sh <cluster-name>

# Stop the tunnels:
./scripts/expose-ew-on-host.sh down <cluster-name>
```

At the end it prints the LAN endpoints the **other** machine should pass to
`peer-with.sh` (typically `<your-LAN-IP>:15008`).

### `scripts/peer-with.sh`

Consumes the peer bundle (`peer-bundle-<peer>.tar.gz`) shipped from the OTHER
machine and finishes the peering on this side.

```bash
./scripts/peer-with.sh <local-cluster-name> <path-to-peer-bundle.tar.gz> <peer-ew-host:port>

# Example: peer is on 192.168.1.42, peer ran expose-ew-on-host.sh:
./scripts/peer-with.sh green /tmp/peer-bundle-blue.tar.gz 192.168.1.42:15008
```

What it does:

1. Extracts the bundle into a tempdir and validates its contents.
2. Verifies the **local** `cacerts` secret's `root-cert.pem` SHA256 matches
   the bundle's `root-ca.crt` SHA256. If they differ, bails with a clear
   error: the two clusters' intermediates must chain to the same root or
   cross-cluster mTLS will silently fail.
3. Applies no credential at all. There is no remote secret in the bundle and
   none is created: the peer Gateway in the next step carries both the HBONE
   endpoint (`:15008`) and the xDS endpoint (`:15012`) that the two control
   planes federate over, so the peer's kube API is never contacted.
4. Creates an `istio-remote` Gateway CR
   (`istio-remote-peer-<peer-name>` in `istio-gateways`) pointing at the
   peer's LAN endpoint with listeners on HBONE (port from the third arg) and
   XDS (port + `PEER_XDS_OFFSET`, default `+4`). This is the same shape
   `istioctl multicluster link` produces in the same-host flow, with the LAN
   IP substituted for the unreachable bridge IP.

Only does one direction: run the same command on the other machine with the
roles swapped to complete the symmetric peering.

Verify peering with `istioctl --context kind-<local> multicluster check`.

### Two-host flow with the helpers

```bash
# === On machine A ===
./scripts/quick-single.sh blue
./scripts/expose-ew-on-host.sh blue
# → prints  192.168.1.10:15008 / :15012 / :15021
scp certs/peer-bundle-blue.tar.gz user@machine-b:/tmp/

# === On machine B ===
scp user@machine-a:/path/to/istio-gw-multi-cluster-kind/certs/root-ca.* certs/
./scripts/quick-single.sh green
./scripts/expose-ew-on-host.sh green
# → prints  192.168.1.42:15008 / :15012 / :15021
./scripts/peer-with.sh green /tmp/peer-bundle-blue.tar.gz 192.168.1.10:15008
scp certs/peer-bundle-green.tar.gz user@machine-a:/tmp/

# === Back on machine A ===
./scripts/peer-with.sh blue /tmp/peer-bundle-green.tar.gz 192.168.1.42:15008

# === Verify on either side ===
istioctl --context kind-blue multicluster check
```

The helpers expect a LAN-reachable kube-API endpoint for each cluster. The
simplest path is a separate `socat` container forwarding the kind control-
plane's published port (Docker Desktop binds it on `127.0.0.1:<random>`),
fronted on the host LAN IP with the same `-p HOST_LAN_IP:6443:6443` pattern;
pass `PEER_API_HOST_PORT=<peer-lan-ip>:6443` to `peer-with.sh`.

## See also

* [`quick.sh`](./quick.sh): same-host two-cluster standup. Use this when both
  clusters live on one machine.
* [`../../agentgw-multi-cluster-kind/scripts/quick-single.sh`](../../agentgw-multi-cluster-kind/scripts/quick-single.sh)
 : the equivalent single-cluster standup for the **Enterprise agentgateway**
  pattern (adds the agentgateway control plane on top of the same Solo Istio
  Ambient platform, and uses the `peering` helm chart for the east-west GW
  instead of `istioctl multicluster expose`).
