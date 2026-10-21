# Istio Ambient Policies on kind, with Bookinfo and YAML from Flightbay (OSS)

One kind cluster, `ambient-policies-lab`, running upstream Istio 1.30.6 in
ambient mode. Images come from `docker.io/istio`, the charts from the upstream
Helm repo and istioctl from the upstream GitHub release. No licence, no
registry login. Istio Bookinfo is deployed and enrolled with Flightbay's
Deploy Bookinfo wizard, which also creates the namespace waypoint
`bookinfo-waypoint`. Then the policies go on `ratings` one at a time, and the
same five requests run after each.

Most of the policy YAML was generated with Flightbay's config wizard
(Flightbay 0.4.5, live mode against the lab cluster). Hand-written files say so
in their first comment.

Lab page: <https://www.masterthemesh.com/solo/istio-ambient-policies-oss-kind/>

## Steps

| Step | Script / tool | What happens |
|---|---|---|
| 1 | `scripts/01-setup.sh` | kind (1 control plane, 2 workers), Gateway API CRDs v1.5.1, istioctl into `.bin/`, helm `base`, `istiod` (`profile=ambient`), `cni`, `ztunnel` |
| 2 | Flightbay: Deploy Bookinfo | namespace `bookinfo` with `istio.io/dataplane-mode=ambient`, waypoint `bookinfo-waypoint`, Bookinfo 1.20.2 and `demo-client` |
| 3 | `scripts/02-check-bookinfo.sh` | legacy (curl, outside the mesh); reads back the labels, waypoint and HBONE; probe all 200 |
| 4 | `scripts/03-strict-mtls.sh` | Policy 1: PeerAuthentication `ratings-strict-mtls` (Flightbay: Require mTLS). legacy gets `000` |
| 5 | `scripts/04-l4-authz.sh` | Policy 2: `ratings-l4`, reviews only (hand-written). Every in-mesh caller gets `503`. Then `ratings-require-waypoint` (Flightbay: Block traffic that skips the waypoint) and `ratings-l4` is deleted |
| 6 | `scripts/05-l7-authz.sh` | Policy 3: `ratings-access-rule`, reviews may GET (Flightbay: Allow or deny requests). POST and demo-client get `403` |
| 7 | `scripts/06-jwt.sh` | Policy 4: `ratings-jwt` and `ratings-jwt-jwt-allow` (Flightbay: Require a JWT). POST: 403 no token, 401 bad token, 200 signed token. demo-client with the token also gets 200, so `52-jwt-allow-reviews-only.yaml` (hand-written) adds the reviews identity |
| | `scripts/99-teardown.sh` | `kind delete cluster --name ambient-policies-lab`, then checks the cluster, node containers and kubeconfig context are gone |

`scripts/probe.sh` calls `http://ratings.bookinfo:9080/ratings/0`: reviews-v2
GET, reviews-v2 POST, demo-client GET, legacy GET and (from step 7)
reviews-v2 POST with `jwt/demo.jwt`.

## Run it

```bash
./scripts/quick.sh up          # everything unattended, with checks (scripts/e2e.sh)
./scripts/quick.sh test        # check the end state of a cluster that is already up
./scripts/quick.sh teardown
```

`quick.sh up` can't click through the Flightbay wizard, so it deploys Bookinfo
with `test-helpers/deploy-bookinfo.sh`: the manifests Flightbay v0.4.5 bundles,
unchanged. That helper is for the harness only. By hand, run
`./scripts/01-setup.sh`, deploy Bookinfo in Flightbay, then `02` to `06`.

You need docker, kind, kubectl, helm and curl. `ISTIO_VERSION` (default 1.30.6)
moves the charts, images and istioctl together.

## Flightbay

You need Flightbay to deploy Bookinfo. The policy scripts use the files in
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
flightbay ui --live --context kind-ambient-policies-lab \
  --namespaces bookinfo,legacy,istio-system,kube-system --cluster-scoped
```

Then Istio Ambient, Deploy Bookinfo demo. For the policies, `bookinfo/ratings`,
Configuration. Screenshots (light theme) are in `img/`.

## Layout

```
kind/cluster.yaml              1 control plane, 2 workers, no port mappings
scripts/                       01..06, probe.sh, e2e.sh, quick.sh, 99-teardown.sh, lib.sh
test-helpers/                  deploy-bookinfo.sh + Flightbay's bundled Bookinfo YAML (harness only)
yaml/00-namespaces.yaml        legacy (no mesh label)
yaml/10-apps/10-legacy.yaml    the caller outside the mesh (hand-written)
yaml/20-policies/
  10-peerauth-strict.yaml            Policy 1        Flightbay: Require mTLS
  20-l4-authz-ratings.yaml           Policy 2        hand-written
  31-require-waypoint.yaml           Policy 2 fixed  Flightbay: Block traffic that skips the waypoint
  40-l7-authz-ratings.yaml           Policy 3        Flightbay: Allow or deny requests
  50-jwt.yaml                        Policy 4        Flightbay: Require a JWT
  52-jwt-allow-reviews-only.yaml     Policy 4 fixed  hand-written
jwt/demo.jwt                   Istio's published test token (iss/sub testing@secure.istio.io)
img/                           Flightbay screenshots (light theme)
```

## What a refusal means

| Caller sees | Decided by | Policy |
|---|---|---|
| `000` connection reset | ztunnel on the destination node | STRICT, or an L4 AuthorizationPolicy |
| `503` (`UC` in the waypoint log) | ztunnel, one hop after the waypoint | an L4 policy that doesn't allow the waypoint's identity |
| `403` | the waypoint | an L7 AuthorizationPolicy |
| `401` | the waypoint | a RequestAuthentication (the token failed verification) |
