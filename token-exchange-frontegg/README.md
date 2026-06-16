# Frontegg as a token-exchange IdP on Solo Enterprise Agentgateway

Companion YAML for the article *RFC 8693 token exchange across identity providers*
(https://www.masterthemesh.com/solo/token-exchange-idp-setup/). The article covers
Entra, Keycloak, Auth0 and Okta. This folder works through what changes when the IdP
is **Frontegg**.

Sample subdomain throughout: `acme.frontegg.com`. CRD shapes match chart line v2026.6.0
and were checked against the on-disk EnterpriseAgentgatewayPolicy / EnterpriseAgentgatewayBackend
schemas.

## The short answer

Frontegg splits into the same two legs the article describes, and the answer is
different for each.

| Leg | Frontegg | Notes |
|-----|----------|-------|
| Inbound validation (validate the user's JWT) | **Yes, drop-in** | Frontegg is a standard OIDC/OAuth2 provider with a public JWKS endpoint. Point the install-time `subjectValidator` / `apiValidator` at it like any other IdP. |
| MCP OAuth discovery (gateway advertises auth to clients) | **Yes, drop-in** | Standard `traffic.jwtAuthentication` + `mcp` block validating Frontegg-issued tokens. |
| Upstream exchange (the RFC 8693 swap) | **Not as a drop-in** | Frontegg's hosted `/oauth/token` does **not** expose `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`. See below. |

So Frontegg is **not** a fifth entry alongside Keycloak/Auth0/Okta for the generic
`tokenExchange.elicitation` flow. It is a fully supported inbound IdP and discovery
authority; it is not a standard RFC 8693 exchange target.

## Why the exchange leg doesn't drop in

The generic elicitation path (`backend.tokenExchange.elicitation`) POSTs a standard
RFC 8693 request to the IdP's `access_token_url`:

```
grant_type = urn:ietf:params:oauth:grant-type:token-exchange
subject_token = <inbound user JWT>
audience = <downstream resource>
```

Frontegg's public hosted-login `/oauth/token` endpoint supports the OAuth grant types
Frontegg lists on its own grant-types page: `authorization_code`, PKCE, `implicit`,
`device_code`, `client_credentials`, `refresh_token`, ROPC. The RFC 8693
`token-exchange` grant is **not** in that set, so the elicitation POST gets rejected.

Frontegg *does* have a feature it calls "Token Exchange" with a delegation toggle, but
it is a different thing: a vendor / environment-management flow where a
**client-credentials** token (clientId + secret) acts on behalf of a user or account,
and the delegation switch is flipped through Frontegg's identity API using an
environment JWT. That is not the gateway presenting the inbound user token back to the
IdP for a downstream-scoped swap, and there is no Frontegg-native policy block in the
CRD (the way Entra gets its `tokenExchange.entra`). So it can't be wired through
`backend.tokenExchange` today.

`03-frontegg-exchange-policy.yaml` and its Secret are included for completeness and so
the shape is on record, but they are **marked non-functional against Frontegg's hosted
endpoint** — they will parse and attach, and the swap will fail at request time.

## What you can actually stand up today

1. `00-tokenexchange-helm-values.yaml` — install-time validators pointed at Frontegg's JWKS. Inbound validation works.
2. `01-frontegg-jwks-backend.yaml` — the static JWKS backend the gateway dials on 443.
3. `04-frontegg-mcp-discovery.yaml` — route-level JWT validation + MCP discovery, validating Frontegg tokens.

One verified gotcha on the discovery policy: `mcp.provider` is an enum that only
accepts `Auth0` or `Keycloak` (checked live against the CRD with a server dry-run).
Frontegg has no hint value, so omit the field, the same as Okta in the article's table.
All three supported objects above pass `kubectl apply --dry-run=server` against the
running enterprise-agentgateway CRDs.

That gives you Frontegg as the inbound identity authority end to end. The downstream
swap would need either (a) Frontegg shipping a hosted RFC 8693 grant, or (b) a
Frontegg-native exchange block in the agentgateway CRD, or (c) fronting the swap with
a provider that does speak RFC 8693.

## Confirm before you apply

These two values depend on the Frontegg environment and should be read from the portal
under **Environment → Authentication → SSO → Identity Provider → OpenID Connect
Endpoints**, not assumed:

- **Issuer** — the `iss` your hosted-login access tokens actually carry.
- **JWKS URI** — Frontegg hosted login typically serves keys at
  `https://<subdomain>.frontegg.com/.well-known/jwks.json`, and discovery at
  `https://<subdomain>.frontegg.com/oauth/.well-known/openid-configuration`. Verify both
  against the panel.

Also set the `aud` you want via Frontegg's JWT claims configuration (Frontegg's `aud`
accepts clientId or appId), or the validator's audience check won't line up.

## Status

Not run end to end. There is no Frontegg tenant in the local secrets and the
agentgateway `tokenExchange` server is not currently enabled on the running clusters,
so this is a design + verified-shape drop, not a captured run.
