# Sidecar to Ambient Upgrade

A hands-on, namespace-by-namespace migration of a running petstore app from
Istio **sidecar** mode to **ambient**, on the Solo distribution of Istio,
installed and driven by the Gloo Operator. One kind cluster. Zero downtime the
whole way, checked with a load generator that never stops, and a clean rollback
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

The lab is run **step by step** from the guide (`index.html`): the numbered
**STEP** blocks are the exact commands and raw YAML to copy-paste, top to bottom
— kind + the Gloo Operator + Solo Istio (sidecar), deploy the petstore app, turn
the mesh ambient, migrate the L4 then the L7 namespace behind a waypoint, route
the mixed fleet, move the canary to HTTPRoute, roll back, and tear down. Every
Istio object is applied inline with `kubectl apply -f - <<'EOF'`, so you can see
exactly what goes into the cluster; there is no hidden script.

The same manifests live in `yaml/` for reference (and the mirror). Prerequisites:
Docker, `kind`, `kubectl`, `helm`, `gcloud` authenticated (Solo images), and
`export SOLO_ISTIO_LICENSE_KEY=...`. An optional appendix drives the
`gloo ambient` CLI (`estimate` and `migrate`).

> `scripts/setup-cluster.sh` bundles STEP 1–4 for the automated end-to-end
> runner; the guide unrolls those same commands so a reader can follow them.

## See it in the UIs

Each visual step (STEP 5–14) carries **Gloo UI** and **Kiali** tabs alongside
Action and Verify, showing what the service graph looks like at that point.

`scripts/setup-cluster.sh` installs both after the mesh is up (via
`scripts/observability.sh`; set `WITH_UI=0` to skip):

- **Gloo UI** — Solo's own dashboard. This is the Gloo Platform management plane
  (mgmt server + agent + Gloo UI) layered onto the same kind cluster. Needs
  `GLOO_PLATFORM_LICENSE_KEY`; open with `meshctl dashboard`, then Observability →
  Graph. Without the licence the Gloo UI is skipped and only Kiali installs.
- **Kiali** — pointed at the Gloo Platform Prometheus. On the Solo distribution
  ztunnel emits L7 metrics with no waypoint, so Kiali shows an HTTP graph even in
  the L4-only `petstore-data` namespace. Open with
  `kubectl -n istio-system port-forward svc/kiali 20001`.

`scripts/open-consoles.sh` port-forwards both UIs and opens them in your browser
(Gloo UI `:8090`, Kiali `:20001`) — run it once the cluster is up.

Screenshots live in `images/` as `step-<NN>-gloo.png` / `step-<NN>-kiali.png`
(see `images/README.md`); a step's tab shows a placeholder until its PNG exists.

## What "zero downtime" means here

`fortio` in the legacy namespace drives `catalog` continuously. At every cut —
the ambient flip, each namespace enrolment, the HTTPRoute cutover, the rollback
— the lab reads fortio's report and shows 100% `200`s. In production you would
run that load continuously and watch the error count stay flat; here each step
prints a bounded run so the result is deterministic and reproducible on a laptop.
