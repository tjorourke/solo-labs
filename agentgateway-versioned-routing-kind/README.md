# agentgateway-versioned-routing-kind

Part 2 of the versioned-routing exploration. Same use case as
[`kgateway-versioned-routing-kind`](../kgateway-versioned-routing-kind/), same
three kind clusters, same seven scenarios. The only change is the data plane:
this runs on Solo Enterprise for agentgateway (the Rust data plane) instead of
kgateway (Envoy).

It reuses the three clusters from part 1 and installs agentgateway into the
same edge cluster, alongside the kgateway install, in its own namespace.

| Cluster      | Role                                                            |
| ------------ | --------------------------------------------------------------- |
| `kgw-edge`   | gets agentgateway too, in `agentgateway-system` (coexists with kgateway in `kgateway-system`). |
| `app-latest` | the "latest" versioned app. Echo server reporting `latest`.     |
| `app-v2`     | a pinned older version. Echo server reporting `v2`.             |

## The same result, a different mechanism

Both gateways give the identical, spoof-safe behaviour across all seven
scenarios. What differs is how you express it:

| | kgateway (part 1) | agentgateway (part 2) |
| --- | --- | --- |
| Policy CRD | `EnterpriseKgatewayTrafficPolicy` | `EnterpriseAgentgatewayPolicy` |
| JWT | `spec.entJWT.beforeExtAuth` | `spec.traffic.jwtAuthentication`, `mode: Optional` |
| tokenless requests allowed | `validationPolicy: AllowMissing` | `mode: Optional` |
| claim to header | first-class `claimsToHeaders` | CEL `transformation.request.set`, `value: "jwt.version"` |
| runs before routing | implicit | explicit `traffic.phase: PreRouting` |
| inline JWKS | `jwks.local.key` | `jwks.inline` |
| static backend | `Backend`, `static.hosts[]` (list) | `AgentgatewayBackend`, `static.host`+`port` (singular) |

agentgateway has no `claimsToHeaders`. You validate the token with
`jwtAuthentication`, then a CEL transformation copies the `version` claim into
`x-tenant-version`. `phase: PreRouting` makes both run before route selection,
so the `HTTPRoute` can match the derived header.

## Verified behaviour

Confirmed live against agentgateway v2.3.4, the same as part 1:

- **JWT-claim routing works.** The CEL transformation projects `version` into
  `x-tenant-version` and the HTTPRoute re-routes on it; the header reaches the
  backend.
- **The claim header is spoof-safe.** A client that sends `x-tenant-version`
  itself has it cleared before routing, even with no token, so it cannot fake
  its version. The explicit override rides a separate header
  (`x-version-override`).
- **Precedence:** explicit override > JWT claim > default-to-latest.
- **`mode: Optional`** lets tokenless requests through but still 401s a present
  but invalid token.

| Request                                   | Served by | Note                          |
| ----------------------------------------- | --------- | ----------------------------- |
| no header, no token                       | latest    | default                       |
| `x-version-override: v2`                  | v2        | explicit client header        |
| client `x-tenant-version: v2`             | latest    | stripped by the transformation |
| JWT `version=v2`                          | v2        | claim projected + re-routed   |
| JWT `version=latest`                      | latest    | claim routed                  |
| JWT `version=v2` + `x-version-override: latest` | latest | override beats the claim   |
| invalid JWT                               | 401       | Optional still rejects        |

## Layout

```
agentgateway-versioned-routing-kind/
├── kind/                      # same three cluster configs as part 1
├── scripts/
│   ├── lib.sh                 # agentgateway chart coords, license, 3 contexts
│   ├── 01-clusters.sh         # ensure 3 clusters (reuses part 1's) + GW API CRDs
│   ├── 02-agentgateway.sh     # install enterprise-agentgateway (skips shared CRDs)
│   ├── 03-apps.sh             # ensure the version-stamped echo apps
│   ├── 04-routing.sh          # AgentgatewayBackends + JWKS + JWT policy + HTTPRoute
│   ├── mint-token.sh          # mint an RS256 JWT with a version claim
│   ├── demo.sh                # run the seven routing scenarios
│   └── quick.sh               # up | demo | teardown | teardown-clusters | status
└── yaml/
    ├── app/echo.yaml          # same stdlib-Python echo as part 1
    └── edge/                  # gateway, backends, jwt-policy, httproute
```

## Run it

This lab needs one secret: a Solo Enterprise agentgateway license key. It is
read from `AGENTGATEWAY_LICENSE_KEY`.

```bash
# Option A — export it:
export AGENTGATEWAY_LICENSE_KEY="your-license-key"
./scripts/quick.sh up

# Option B — keep it in a sourceable file (export AGENTGATEWAY_LICENSE_KEY=...):
SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up

./scripts/quick.sh demo              # run the seven scenarios
./scripts/quick.sh teardown          # remove agentgateway, KEEP the clusters
./scripts/quick.sh teardown-clusters # delete all three clusters (also removes part 1)
```

Because it reuses part 1's clusters, the shared `extauth.solo.io` /
`ratelimit.solo.io` CRDs are already owned by the kgateway CRDs chart.
`02-agentgateway.sh` detects that and installs the agentgateway CRDs chart with
`installExtAuthCRDs=false` / `installRateLimitCRDs=false`, so the two enterprise
installs coexist. On a standalone run (no part 1) it installs them normally.
