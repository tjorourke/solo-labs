# Istio Ambient Policies on kind, with YAML from Flightbay (OSS)

One kind cluster, `ambient-policies-lab`, running upstream Istio 1.30.6 in
ambient mode. Images come from `docker.io/istio`, the charts from the upstream
Helm repo and istioctl from the upstream GitHub release. No licence, no
registry login. A small shop app is enrolled with one namespace label. Then the
policies go on one at a time, and the same five requests run after each.

Most of the policy YAML was generated with Flightbay's config wizard
(Flightbay 0.4.5, live mode against the lab cluster). Two files are written by
hand because Flightbay has no task for them. Each file says which it is in its
first comment.

Lab page: <https://www.masterthemesh.com/solo/istio-ambient-policies-oss-kind/>

## Steps

| Step | Script | What happens |
|---|---|---|
| 1 | `scripts/01-setup.sh` | kind (1 control plane, 2 workers), Gateway API CRDs v1.5.1, istioctl into `.bin/`, helm `base`, `istiod` (`profile=ambient`), `cni`, `ztunnel` |
| 2 | `scripts/02-deploy-apps.sh` | catalog (go-httpbin), checkout and reporting (curl) in `shop`; legacy (curl) outside the mesh. One label enrols `shop`. PROTOCOL goes from `TCP` to `HBONE` |
| 3 | `scripts/03-strict-mtls.sh` | Policy 1: PeerAuthentication `catalog-strict-mtls` (Flightbay: Require mTLS). legacy gets `000` |
| 4 | `scripts/04-l4-authz.sh` | Policy 2: AuthorizationPolicy `catalog-l4`, checkout only (hand-written). reporting gets `000`; checkout DELETE still 200 |
| 5 | `scripts/05-waypoint.sh` | Waypoint and namespace labels (Flightbay: Set up a waypoint). Every in-mesh caller gets `503`. Then `catalog-require-waypoint` (Flightbay: Block traffic that skips the waypoint) and `catalog-l4` is deleted |
| 6 | `scripts/06-l7-authz.sh` | Policy 3: `catalog-access-rule`, checkout may GET (Flightbay: Allow or deny requests). DELETE and reporting get `403` |
| 7 | `scripts/07-jwt.sh` | Policy 4: RequestAuthentication `catalog-jwt` and `catalog-jwt-jwt-allow` (Flightbay: Require a JWT). 403 no token, 401 bad token, 200 signed token. reporting with the token also gets 200, so `52-jwt-allow-checkout-only.yaml` (hand-written) adds checkout's identity. reporting then gets 403 |
| | `scripts/99-teardown.sh` | `kind delete cluster --name ambient-policies-lab`, then checks the cluster, node containers and kubeconfig context are gone |

`scripts/probe.sh` prints the table: checkout GET, checkout DELETE, reporting
GET, legacy GET and (from step 7) checkout DELETE with `jwt/demo.jwt`.

## Run it

```bash
./scripts/quick.sh up          # everything, with checks after every step (scripts/e2e.sh)
./scripts/quick.sh test        # check the end state of a cluster that is already up
./scripts/quick.sh teardown
```

Or run `./scripts/01-setup.sh` to `./scripts/07-jwt.sh` in order. Each script
prints the kubectl, helm and istioctl commands it runs.

You need docker, kind, kubectl, helm and curl. istioctl is downloaded into
`.bin/` (gitignored). `ISTIO_VERSION` (default 1.30.6) moves the charts, images
and istioctl together. `CLUSTER_NAME` (default `ambient-policies-lab`) changes
the cluster name.

## Flightbay

You only need Flightbay to regenerate the YAML. The scripts use the files in
`yaml/20-policies/`.

macOS:

```bash
brew update
brew tap tjorourke/flightbay https://github.com/tjorourke/flightbay
brew install tjorourke/flightbay/flightbay
```

Linux: download `flightbay_<version>_linux_<arch>.tar.gz` from
<https://github.com/tjorourke/flightbay/releases/latest>. It contains
`flightbay` and `flightbay-desk`. The desk runs on macOS and Linux only; the
collector also runs on Windows.

Open the wizard against the lab cluster:

```bash
flightbay ui --live --context kind-ambient-policies-lab --namespaces shop,legacy,istio-system
```

Then Istio Ambient, `shop/catalog`, Configuration. Screenshots of each task are
in `img/`.

## Layout

```
kind/cluster.yaml              1 control plane, 2 workers, no port mappings
scripts/                       01..07, probe.sh, e2e.sh, quick.sh, 99-teardown.sh, lib.sh
yaml/00-namespaces.yaml        shop, legacy (no mesh labels; enrolment is a step)
yaml/10-apps/                  catalog, checkout, reporting, legacy
yaml/20-policies/
  10-peerauth-strict.yaml            Policy 1        Flightbay: Require mTLS
  20-l4-authz-catalog.yaml           Policy 2        hand-written
  30-waypoint.yaml                   waypoint        Flightbay: Set up a waypoint
  31-require-waypoint.yaml           Policy 2 fixed  Flightbay: Block traffic that skips the waypoint
  40-l7-authz-catalog.yaml           Policy 3        Flightbay: Allow or deny requests
  50-jwt.yaml                        Policy 4        Flightbay: Require a JWT
  52-jwt-allow-checkout-only.yaml    Policy 4 fixed  hand-written
jwt/demo.jwt                   Istio's published test token (iss/sub testing@secure.istio.io)
img/                           Flightbay wizard screenshots
```

## What a refusal means

| Caller sees | Decided by | Policy |
|---|---|---|
| `000` connection reset | ztunnel on the destination node | STRICT, or an L4 AuthorizationPolicy |
| `503` (`UC` in the waypoint log) | ztunnel, one hop after the waypoint | an L4 policy that doesn't allow the waypoint's identity |
| `403` | the waypoint | an L7 AuthorizationPolicy |
| `401` | the waypoint | a RequestAuthentication (the token failed verification) |
