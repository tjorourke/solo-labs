# Istio Ambient on kind: Install and Four Policies, OSS Edition

One kind cluster running **upstream community Istio in ambient mode** from the
first helm install: images from `docker.io/istio`, upstream Helm charts,
istioctl from the upstream GitHub release. No licence, no registry auth, no
sidecar phase. A small shop app is enrolled with one namespace label, and then
four policies land one at a time. After each one the same five requests run
again, so what changed, and which proxy changed it, is visible in a table.

Lab page: <https://www.masterthemesh.com/solo/istio-ambient-policies-oss-kind/>

## What it covers

| Step | Script | What happens |
|---|---|---|
| 1 | `scripts/01-setup.sh` | kind (1 control plane + 2 workers), Gateway API CRDs, istioctl downloaded into `.bin/`, helm `base` + `istiod` (`profile=ambient`) + `cni` + `ztunnel` |
| 2 | `scripts/02-deploy-apps.sh` | catalog (go-httpbin), checkout and reporting (curl) in `shop`; legacy (curl) outside the mesh. One label enrols `shop`, no restart. PROTOCOL flips `TCP` to `HBONE` |
| 3 | `scripts/03-strict-mtls.sh` | **Policy 1** PeerAuthentication STRICT, mesh-wide. legacy is reset (curl `000`) |
| 4 | `scripts/04-l4-authz.sh` | **Policy 2** AuthorizationPolicy `catalog-l4` by identity, enforced by ztunnel. reporting is reset; checkout DELETE still 200 |
| 5 | `scripts/05-waypoint.sh` | A waypoint for `shop`. Every in-mesh caller gets **503**: the hop to the pod now comes from the waypoint's identity, which `catalog-l4` refuses. Revise it to admit the waypoint |
| 6 | `scripts/06-l7-authz.sh` | **Policy 3** AuthorizationPolicy `catalog-l7` with `targetRefs` to the Service: checkout may GET. DELETE and reporting get 403. A call to the pod IP skips the waypoint and is reset by `catalog-l4` |
| 7 | `scripts/07-jwt.sh` | **Policy 4** RequestAuthentication (inlined JWKS) + a DELETE rule that needs a verified JWT and the checkout identity. 403 no token, 401 bad token, 200 signed token, 403 for reporting with the same token |
| | `scripts/99-teardown.sh` | `kind delete cluster --name ambient-policies` |

`scripts/probe.sh` is the table: checkout GET, checkout DELETE, reporting GET,
legacy GET, and (from step 7) checkout DELETE with `jwt/demo.jwt`.

## Run it

```bash
./scripts/quick.sh up          # everything, with assertions after every step (scripts/e2e.sh)
./scripts/quick.sh test        # assert the end state of a cluster that is already up
./scripts/quick.sh teardown
```

Or step by step, `./scripts/01-setup.sh` through `./scripts/07-jwt.sh`. Each
script prints the kubectl, helm and istioctl commands it runs.

Needs docker, kind, kubectl, helm, curl. istioctl is downloaded for you
(`.bin/`, gitignored). `ISTIO_VERSION` (default 1.30.6) moves the whole lab,
charts, images and istioctl together.

## Layout

```
kind/cluster.yaml              1 control plane + 2 workers, no port mappings
scripts/                       01..07, probe.sh, e2e.sh, quick.sh, 99-teardown.sh, lib.sh
yaml/00-namespaces.yaml        shop, legacy (no mesh labels; enrolment is a step)
yaml/10-apps/                  catalog, checkout, reporting, legacy
yaml/20-policies/
  10-peerauth-strict.yaml            Policy 1
  20-l4-authz-catalog.yaml           Policy 2, as first written (allow checkout)
  30-waypoint.yaml                   the Gateway, class istio-waypoint
  31-l4-authz-catalog-waypoint.yaml  Policy 2, revised (allow the waypoint)
  40-l7-authz-catalog.yaml           Policy 3
  50-jwt-requestauth.yaml            Policy 4, the RequestAuthentication
  51-l7-authz-catalog-jwt.yaml       Policy 4, catalog-l7 with the DELETE rule
jwt/demo.jwt                   Istio's published test token (iss/sub testing@secure.istio.io)
```

## Reading a refusal

| Caller sees | Decided by | Policy |
|---|---|---|
| `000` connection reset | ztunnel on the destination node | STRICT, or an L4 AuthorizationPolicy |
| `503` (`UC` in the waypoint log) | ztunnel, one hop after the waypoint | an L4 policy that does not admit the waypoint's identity |
| `403` | the waypoint | an L7 AuthorizationPolicy |
| `401` | the waypoint | a RequestAuthentication (token failed verification) |
