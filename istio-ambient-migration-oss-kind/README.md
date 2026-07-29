# Sidecar to Ambient, OSS Edition

A hands-on, namespace-by-namespace migration of a running petstore app from
Istio **sidecar** mode to **ambient**, entirely on **upstream community
Istio**: images from `docker.io/istio`, upstream Helm charts, no licence, no
registry auth, no enterprise CRDs. One kind cluster. Zero downtime at every
cut, checked with a load generator, and a clean rollback (and re-enrolment)
at the end.

The two headline moves:

- **The switch.** The mesh grows an ambient dataplane with a helm upgrade
  (istiod `profile=ambient` + the `cni` and `ztunnel` charts) while sidecars
  keep serving. After that, each namespace migrates with **one label flip**
  (`istio-injection=enabled` → `istio.io/dataplane-mode=ambient`) and a
  rolling restart, and flips back the same way.
- **One waypoint for the whole cluster.** Instead of a waypoint per
  namespace, a single Gateway (`istio-waypoint` class, `allowedRoutes:
  namespaces.from: All`) lives in `mesh-infra`, and every L7 namespace
  attaches to it with two labels (`istio.io/use-waypoint` +
  `istio.io/use-waypoint-namespace`). Two app namespaces share it in this
  lab; the L4-only namespace never needs one.

It covers, in order:

1. Upstream Istio in **sidecar** mode (helm: `base` + `istiod`).
2. A petstore app across four namespaces: `petstore` (catalog v1/v2 canary
   with DestinationRule + VirtualService, GET-only HTTP AuthorizationPolicy),
   `petstore-orders` (a second L7 namespace), `petstore-data` (a TCP data
   store with STRICT mTLS + identity-based L4 authz), and `petstore-clients`
   (fortio + a curl client).
3. The ambient dataplane arriving **under load** (fortio scores 100%), then
   one roll of every namespace so re-injected sidecars advertise HBONE.
4. Migrating the **L4-only** namespace with no waypoint (ztunnel keeps mTLS
   and the same selector-based L4 AuthorizationPolicy).
5. The canary moving from DR/VS subsets to per-version Services + an
   **HTTPRoute** (waypoints do not do subset routing), a traffic no-op.
6. Deploying the **one cluster-wide waypoint** and migrating both L7
   namespaces behind it (`selector` → `targetRefs` policy transform first).
7. The mixed-fleet gap, shown live: a caller still on a sidecar **bypasses**
   the waypoint, so the GET-only rule does not apply to it until its own
   namespace migrates. (Closing that gap during a long migration, sidecar
   and ingress traffic routed *through* waypoints, is what the Solo
   distribution adds; see the Enterprise edition of this lab.)
8. Migrating the calling estate: the same DELETE now comes back 403, and the
   HTTPRoute canary shifts live at the waypoint.
9. **Rollback**: one namespace goes back to sidecars with a single label flip
   (selector policy restored), then forward again.

## Prerequisites

- Docker, `kind`, `kubectl`, `helm`, `istioctl`. No licence, no `gcloud`:
  everything pulls from public registries.

## Run it

The lab is run **step by step** from the guide (`index.html`): the numbered
**STEP** blocks are the exact commands and raw YAML to copy-paste, top to
bottom. Every Istio object is applied inline, so you can see exactly what
goes into the cluster; the only script in the setup path bundles the fiddly
infrastructure (kind, image loading, helm):

```bash
./scripts/setup-cluster.sh     # kind + Gateway API CRDs + upstream Istio (sidecar mode)
# then follow the STEP blocks in the guide
```

`scripts/ambient-enable.sh` bundles the mesh-level switch (istiod
`profile=ambient` + cni + ztunnel) for the automated runner; the guide
unrolls the same three helm commands.

The whole arc, automated and asserted:

```bash
./scripts/e2e.sh               # ~15 min: baseline → ambient → waypoint → rollback
kind delete cluster --name ambient-oss
```

## What "zero downtime" means here

`fortio` in `petstore-clients` drives `catalog` continuously. At every cut (the
ambient standup, each namespace enrolment, the HTTPRoute cutover, the
rollback) the lab reads fortio's report and shows 100% `200`s. In production
you would run that load continuously and watch the error count stay flat;
here each step prints a bounded run so the result is deterministic and
reproducible on a laptop.

## OSS vs Enterprise

Everything in this lab is upstream ambient. The
[Enterprise edition](../istio-ambient-migration-kind/) runs the same migration on the Solo
distribution via the Gloo Operator, where the extra piece is mixed-fleet
interop (`ENABLE_WAYPOINT_INTEROP`): sidecar and ingress traffic routed
through waypoints, so L7 policy holds for callers that have not migrated yet.
