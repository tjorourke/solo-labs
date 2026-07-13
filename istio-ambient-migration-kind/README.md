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

One script sets up the infrastructure; everything after that is `kubectl apply`
of the manifests in `yaml/` plus a few labels, so you can read and talk through
each change. The full step-by-step (with what to expect at each step) is in the
lab guide — the numbered **STEP** blocks under "Run the lab, step by step". In
brief:

```bash
export SECRETS_FILE=/path/to/secrets-envs.sh   # exports SOLO_ISTIO_LICENSE_KEY

./scripts/setup-cluster.sh                      # STEP 1: kind + Solo Istio (sidecar) + ingress
kubectl apply -f yaml/10-apps-sidecar/          # STEP 2: petstore app + ingress route
kubectl apply -f yaml/20-policies-sidecar/      # STEP 3: mTLS + DR/VS canary + L4 + L7 rules
kubectl apply -f yaml/00-mesh/smc-ambient.yaml  # STEP 5: turn the mesh ambient (adds ztunnel)
# STEP 6: migrate the L4 namespace, STEP 7: the L7 namespace (waypoint first),
# STEP 8: route the mixed fleet, STEP 9: HTTPRoute, STEP 10: rollback — see the guide.

kind delete cluster --name ambient-migration    # STEP 11: teardown
```

An optional appendix drives the `gloo ambient` CLI (`estimate` and `migrate`).

## What "zero downtime" means here

`fortio` in the legacy namespace drives `catalog` continuously. At every cut —
the ambient flip, each namespace enrolment, the HTTPRoute cutover, the rollback
— the lab reads fortio's report and shows 100% `200`s. In production you would
run that load continuously and watch the error count stay flat; here each step
prints a bounded run so the result is deterministic and reproducible on a laptop.
