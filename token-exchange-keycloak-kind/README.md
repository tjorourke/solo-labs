# Token exchange E2E — Keycloak on kind-a2a-obo (live, captured)

Runnable end-to-end token exchange against the enterprise-agentgateway STS, with
Keycloak as the inbound IdP. This is the first of the four token-exchange-idp-setup
IdPs actually run end to end (the article is verified-shape config; this is a live run).

- Cluster: `kind-a2a-obo`
- enterprise-agentgateway **v2.3.3** (helm release `agentgateway`, chart `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts`)
- Keycloak **26.3.5**, realm `solo`, in-cluster on `http://keycloak.keycloak.svc.cluster.local`
- Run it: `./run-e2e.sh`

## Two token-exchange flows exist — both real, both documented

There are two distinct, officially-documented agentgateway token-exchange flows. The
published article (`token-exchange-idp-setup`) documents the first; this lab happened to
exercise both, which is worth keeping straight (an earlier draft of this note wrongly
called the article's flow incorrect — it isn't):

| | Flow A — IdP-native / OBO | Flow B — built-in STS (remote-actor) |
|---|---|---|
| Who issues the exchanged token | the IdP (Keycloak/Auth0/Okta/Frontegg) | the agentgateway STS (`...:7777`), signs its own |
| What the IdP must support | RFC 8693 grant at its token endpoint | just be a validatable OIDC issuer (JWKS) |
| Solo doc | `obo-token-exchange.md` | `remote-actor-token-exchange.md` |
| The article documents | **this one** (`elicitation.secretName` → IdP swaps) | not covered |

Both are legitimate. Flow A is the post's pattern (the gateway drives the IdP's token
endpoint via the elicitation OAuth Secret; the IdP issues the downstream token). Flow B
is the gateway acting as its own STS (`sts/handler.go processTokenExchange` →
`signer.Generate`, `iss = …:7777`, serves `/jwks`), which Entra-style OBO and agent-to-tool
delegation use.

**Implication for Frontegg:** it works in *both*. Its discovery doc advertises the RFC
8693 grant (Flow A), and it's a validatable OIDC issuer (Flow B). See `../token-exchange-frontegg/`.

## Captured results

**Model B — the agentgateway STS swap (`POST :7777/oauth2/token`):**
```
subject_token = alice's Keycloak access token (iss = .../realms/solo)
->
header: { alg: RS256, kid: E4-UD8eKvBAq61xhebVOXfSW3KDn6C3PTPWhNd0rhwk }
  iss:   enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777   # gateway STS
  sub:   120d71d7-82dc-4432-a77c-e01bfbf26a9d                                  # alice, preserved
  aud:   mcp-downstream                                                        # re-scoped
  scope: openid profile email
  issued_token_type: urn:ietf:params:oauth:token-type:jwt   token_type: Bearer
```

**Model A — Keycloak-native swap (`POST .../realms/solo/.../token`):**
```
  iss: http://keycloak.keycloak.svc.cluster.local/realms/solo   # Keycloak issued it
  sub: 120d71d7-...   aud: mcp-downstream   azp: agentgateway-exchange
```

## Fixes / gotchas found live (vs the article)

1. **`subject_token_type` must be `urn:ietf:params:oauth:token-type:jwt`.** The STS only
   accepts `:jwt` (`access_token`/`id_token`/`refresh_token` are coded but `Not implemented`,
   return `unsupported token type`). `sts/handler.go validateTokenType`.
2. **STS Helm shape is correct for v2.3.3** — `tokenExchange.{enabled,issuer,tokenExpiration,subjectValidator,actorValidator,apiValidator}`. The `/var/db` SQLite volume + KEK secret are auto-created by the chart (in-memory emptyDir); no manual PVC. So no fix needed there, contrary to what I first suspected.
3. **`oidc.secretName` in the article is drift** — in v2.3.3 the install-time default OAuth secret is `tokenExchange.elicitation.secretName`, not `oidc.secretName`.
4. **`mcp.provider` enum only accepts `Auth0`/`Keycloak`** (live CRD dry-run) — no Frontegg/Okta/Entra value; omit it for those.
5. **Model A only — Keycloak STE v2 audience rules** (both required, surfaced as live errors):
   - login client (`mcp-client`) needs an audience mapper adding the exchange client, else `access_denied: Client is not within the token audience`.
   - exchange client (`agentgateway-exchange`) needs an audience mapper adding the downstream, else `invalid_request: Requested audience not available`.
   - `standard.token.exchange.enabled=true` is a client **attribute** (not a create-time field); Keycloak 26.3.5 `TOKEN_EXCHANGE_STANDARD_V2` is on by default.

## What was set up on the cluster (kept for re-runs)

- Helm: `tokenExchange.enabled=true` + validators → Keycloak `solo` certs (`yaml/tokenexchange-values.yaml`).
- Keycloak `solo`: clients `mcp-client` (public, direct grants, aud→agentgateway-exchange),
  `agentgateway-exchange` (confidential, STE, aud→mcp-downstream), `mcp-downstream`; user `alice` pw `password`.
- `te-demo/echo` header-reflector (for a future data-plane forward test).

## Not yet done

The full **data-plane** path (gateway auto-invokes the STS during an MCP request and
forwards the minted token to the backend) is not captured here — proven at the STS level
instead, which is the component that performs the swap. Wiring the MCP route + a real MCP
server is the remaining step if a full request-path capture is wanted.
