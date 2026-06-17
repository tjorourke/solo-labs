# kgateway-versioned-routing-kind

Route a public API to versioned application clusters from a gateway that lives
outside all of them, using Solo Enterprise for kgateway.

Three kind clusters:

| Cluster      | Role                                                        |
| ------------ | ----------------------------------------------------------- |
| `kgw-edge`   | Solo Enterprise for kgateway 2.2.0. The gateway, and nothing else. |
| `app-latest` | The "latest" versioned app. Echo server reporting `latest`. |
| `app-v2`     | A pinned older version. Echo server reporting `v2`.         |

The edge gateway reaches each app cluster as an out-of-cluster `Backend`
(static host = the app cluster's kind node IP + NodePort, over the shared kind
docker network). The app clusters never know about each other, and the gateway
holds the whole routing table. That replaces the fragile pattern of
reverse-proxying from the latest cluster.

## What it shows

Two ways to choose a version, on two different headers, plus a default:

1. **Explicit header** `x-version-override: v2` — client- or ops-controlled.
2. **JWT claim** — the gateway validates a token and projects its `version`
   claim into `x-target-version`, then routes on it.
3. **Default to latest** — no override, no claim, you land on `app-latest`.

The tenant-to-version mapping lives in the IdP as a token claim, keyed off the
tenant. A version rollover is an identity change (update the claim the IdP
issues), not a gateway change.

## Verified behaviour

Everything below was confirmed live against kgateway 2.2.0, not assumed:

- **JWT-claim routing works.** `entJWT.claimsToHeaders` projects the `version`
  claim into `x-target-version` and the HTTPRoute re-routes on it. The
  claim-derived header also reaches the backend.
- **The claim header is spoof-safe.** A client that sends `x-target-version`
  itself has that header stripped before routing, even when no token is
  present. The JWT filter owns that header. So you can't fake your version by
  setting the header the gateway derives from the token. Any *other* client
  header passes through untouched.
- **That is why there are two headers.** Because the JWT filter sanitises its
  own claim target, an explicit client override needs a different header name
  (`x-version-override`) that the filter does not manage.
- **Precedence:** explicit override > JWT claim > default. A request with both
  a `v2` token and `x-version-override: latest` lands on `latest`.
- **`validationPolicy: AllowMissing`** lets tokenless requests through (so the
  override and default paths work) while still returning 401 for a present but
  invalid token.

The seven scenarios, as `./scripts/quick.sh demo` prints them:

| Request                                   | Served by | Note                          |
| ----------------------------------------- | --------- | ----------------------------- |
| no header, no token                       | latest    | default                       |
| `x-version-override: v2`                  | v2        | explicit client header        |
| client `x-target-version: v2`             | latest    | stripped by JWT filter        |
| JWT `version=v2`                          | v2        | claim projected + re-routed   |
| JWT `version=latest`                      | latest    | claim routed                  |
| JWT `version=v2` + `x-version-override: latest` | latest | override beats the claim   |
| invalid JWT                               | 401       | AllowMissing still rejects    |

## Layout

```
kgateway-versioned-routing-kind/
├── kind/                      # edge + app-latest + app-v2 cluster configs
├── scripts/
│   ├── lib.sh                 # shared helpers (3 contexts, chart coords, license)
│   ├── 01-clusters.sh         # create 3 clusters + Gateway API CRDs on edge
│   ├── 02-kgateway.sh         # install enterprise-kgateway + Gateway
│   ├── 03-apps.sh             # deploy version-stamped echo apps
│   ├── 04-routing.sh          # Backends + JWKS + JWT policy + HTTPRoute
│   ├── mint-token.sh          # mint an RS256 JWT with a version claim
│   ├── demo.sh                # run the seven routing scenarios
│   └── quick.sh               # up | demo | teardown | status
└── yaml/
    ├── app/echo.yaml          # stdlib-Python echo (no image build), NodePort
    └── edge/                  # gateway, backends, httproute, jwt-policy
```

## Run it

You need `kind`, `kubectl`, `helm`, `docker`, `gcloud` (for the public chart
registry), `openssl`, and `jq`, plus a Solo Enterprise for kgateway license
key.

This lab needs one secret: a Solo Enterprise for kgateway license key. It is
read from the first of `KGATEWAY_LICENSE_KEY`, `GLOO_GATEWAY_LICENSE_KEY` or
`SOLO_LICENSE_KEY` that is set.

```bash
# Option A — export it:
export KGATEWAY_LICENSE_KEY="your-license-key"
./scripts/quick.sh up

# Option B — keep it in a sourceable file (one line: export KGATEWAY_LICENSE_KEY=...):
SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

./scripts/quick.sh demo       # run the seven scenarios
./scripts/quick.sh status     # show gateway + routing + apps
./scripts/quick.sh teardown   # delete all three clusters
```

Mint a token by hand and drive the gateway yourself:

```bash
kubectl --context kind-kgw-edge -n kgateway-system port-forward svc/http 8080:80 &

TOKEN=$(./scripts/mint-token.sh v2 acme)        # version=v2, tenant=acme
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/ | jq .servedBy
# "v2"

curl -s -H "x-version-override: v2" http://localhost:8080/ | jq .servedBy
# "v2"
```

The RSA keypair, the inline JWKS, and the rendered manifests are written to
`.gen/` (gitignored). The JWKS is embedded in the JWT policy via
`jwks.local.key`, so the whole demo runs offline with no JWKS server.

## How the pieces fit

- `Backend` (`gateway.kgateway.dev`, `type: Static`) per app cluster, host =
  app node IP, port = NodePort 30080.
- `EnterpriseKgatewayTrafficPolicy.spec.entJWT.beforeExtAuth` validates the
  token against the inline JWKS and maps `version` -> `x-target-version`.
- `HTTPRoute` matches `x-version-override` first, then `x-target-version`, then
  falls through to `app-latest`.
