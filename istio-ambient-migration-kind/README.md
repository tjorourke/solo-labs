# Sidecar to Ambient Upgrade

A hands-on, namespace-by-namespace migration of a running petstore app from
Istio **sidecar** mode to **ambient**, on the Solo distribution of Istio,
installed and driven by the Gloo Operator. One kind cluster. Zero downtime the
whole way, proven with a load generator that never stops, and a clean rollback
at the end.

It covers, in order:

1. Solo Istio in **sidecar** mode via a single `ServiceMeshController` CR.
2. A petstore app across three namespaces: an **L7** namespace (`catalog` v1/v2
   canary with a DestinationRule + VirtualService, an HTTP AuthorizationPolicy,
   VS retries/timeout) and an **L4-only** namespace (a TCP data store with
   STRICT mTLS + an identity-based L4 AuthorizationPolicy), plus a **legacy**
   namespace kept on sidecars throughout.
3. Flipping the whole mesh to ambient with **one field** (`dataplaneMode:
   Ambient`) — running sidecar workloads keep serving.
4. Migrating the **L4-only** namespace with no waypoint (ztunnel does it all).
5. Migrating the **L7** namespace: waypoint first, `selector` → `targetRefs`,
   DestinationRule + VirtualService still working at the waypoint.
6. The **Solo-only** capability: sidecar and ingress traffic routed **through a
   waypoint** so its L7 policy is enforced across a mixed fleet
   (`ENABLE_WAYPOINT_INTEROP`, on by default on Solo images).
7. Modernizing the canary from DR/VS subsets to per-version Services +
   **HTTPRoute**, with a zero-downtime weight shift.
8. **Rollback** of a namespace with a single label.
9. A check-by-check migration checklist.

## Why Enterprise

The headline — a sidecar or the Istio ingress gateway sending traffic through an
ambient waypoint so the waypoint's L7 policy is enforced for callers that still
have a sidecar — is a Solo-distribution behaviour (`ENABLE_WAYPOINT_INTEROP`,
default `true` on the Solo images). Community Istio does not route sidecar or
ingress traffic through waypoints, so a waypoint's L7 policy would be silently
unenforced for sidecar callers during a mixed-fleet migration. That is what
makes an incremental, namespace-by-namespace migration safe, and it is why this
lab runs on the Solo images.

## Prerequisites

- Docker, `kind`, `kubectl`, `helm`, `gcloud` (authenticated — the Solo Istio
  images are pulled from `us-docker.pkg.dev/soloio-img/istio`).
- `SOLO_ISTIO_LICENSE_KEY`. Export it, or point `SECRETS_FILE` at a shell file
  that does:
  ```bash
  export SECRETS_FILE=/path/to/secrets-envs.sh
  ```

## Run it

```bash
./scripts/01-cluster.sh      # kind + Gloo Operator + Solo Istio (sidecar mode)
./scripts/02-apps.sh         # petstore app + ingress + sidecar-era policies
```

Then walk the migration in `demo.ipynb`, or drive it with the step scripts:

```bash
./scripts/03-flip-ambient.sh      # dataplaneMode: Ambient — adds ztunnel, zero downtime
./scripts/04-migrate-l4.sh        # enrol petstore-data (no waypoint)
./scripts/05-migrate-l7.sh        # waypoint + targetRefs, enrol petstore
./scripts/06-solo-interop.sh      # sidecar/ingress → waypoint (the Solo capability)
./scripts/07-httproute.sh         # DR/VS subsets → HTTPRoute
./scripts/rollback.sh petstore    # single-label rollback of a namespace
```

`./scripts/health-check.sh` prints the state of the mesh and the app at any
point. `./demo-scripts/reset.sh` tears the cluster down.

## What "zero downtime" means here

`fortio` in the legacy namespace drives `catalog` continuously. At every cut —
the ambient flip, each namespace enrolment, the HTTPRoute cutover, the rollback
— the lab reads fortio's report and shows 100% `200`s. In production you would
run that load continuously and watch the error count stay flat; here each step
prints a bounded run so the result is deterministic and reproducible on a laptop.
