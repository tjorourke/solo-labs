# Sample output — validated on kind (enterprise-agentgateway v2.3.4 / v2026.5.2)

`./scripts/capture-keys.sh`, captured live.

| # | Request | HTTP | Upstream received |
|---|---|---|---|
| 1 | Tom's JWT, `team=sales` | 200 | `Authorization: Bearer SALES-STATIC-KEY-aaaa1111`, `x-team=sales` |
| 2 | Ram's JWT, `team=engineering` | 200 | `Authorization: Bearer ENG-STATIC-KEY-bbbb2222`, `x-team=engineering` |
| 3 | Sales JWT **+ spoofed** `x-team: engineering` | 200 | `Bearer SALES-STATIC-KEY-…`, `x-team=sales` — the `set` overwrote the spoof |
| 4 | No JWT | **401** | request rejected at the gateway |

Each team's request reaches the upstream carrying *its own* static key. The user
only ever sends a JWT; the gateway validates it, picks the backend from the verified
`team` claim, strips the JWT, and injects that team's key.

## AGW gotchas found while building this (all verified live)

1. **Endpoint override is `spec.ai.provider.host` / `.port`**, not `spec.ai.host`
   (the latter is a strict-decoding error on v2.3.4).
2. **`jwks.remote` to a Service left the policy `PartiallyValid`** — "jwks ConfigMap
   … isn't available". `jwks.inline` (the JWKS JSON as a string) sidesteps the
   enterprise ConfigMap-materialisation path and is deterministic. (For a real IdP,
   `jwks.remote.backendRef` at its JWKS URL is the right call.)
3. **`spec.traffic.phase: PreRouting` is required.** Without it, HTTPRoute matching
   runs on the *inbound* headers before the transformation sets `x-team`, so the
   JWT-derived header is never seen by the matcher (404) and a client-supplied
   `x-team` is (spoofable). PreRouting runs JWT + transformation before routing.
4. **Don't `remove` a header you also `set`.** On this build `remove` wins over `set`
   for the same name, deleting the value before routing. A `set` already overwrites
   any client-supplied value, so it is the anti-spoof on its own.
5. **CEL claim accessor is `jwt.<claim>`** (e.g. `jwt.team`, `jwt.sub`) — `jwt.claims`
   does not exist. Confirmed by injecting debug headers and reading them at the upstream.
