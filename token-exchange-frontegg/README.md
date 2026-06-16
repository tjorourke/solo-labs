# Frontegg as a token-exchange IdP on Solo Enterprise Agentgateway

Companion YAML for the article *RFC 8693 token exchange across identity providers*
(https://www.masterthemesh.com/solo/token-exchange-idp-setup/), worked through for
**Frontegg**.

Sample subdomain throughout: `acme.frontegg.com`.

## Verdict: Frontegg works as a token-exchange IdP — both flows

Frontegg works in **both** of agentgateway's token-exchange flows:

- **Flow A — IdP-native / OBO** (the published article's pattern): Frontegg's hosted
  `/oauth/token` advertises the RFC 8693 `token-exchange` grant in its discovery doc
  (verified live), so it slots into the same `elicitation.secretName` config as
  Keycloak/Auth0/Okta and issues the downstream token itself.
- **Flow B — built-in STS** (gateway mints its own token, `iss = …:7777`): only needs
  Frontegg to be a validatable OIDC issuer with a JWKS endpoint, which it is. Proven live
  in `../token-exchange-keycloak-kind/` and exercised with a real Frontegg token here.

(An earlier draft of this note claimed Frontegg "couldn't do the swap" and that the
gateway always self-mints — both overstated. The article documents Flow A, which is a real
Solo capability, and Frontegg supports it.)

| Leg | Frontegg |
|-----|----------|
| Inbound validation (validate the Frontegg user JWT) | ✅ standard OIDC/JWKS |
| The exchange (Flow A: IdP mints; Flow B: gateway STS mints) | ✅ both |
| MCP OAuth discovery (advertise auth to clients) | ✅ standard, one enum caveat below |

## What to configure for Frontegg

1. `00-tokenexchange-helm-values.yaml` — STS enabled, `subjectValidator` + `apiValidator` → Frontegg JWKS. **This is the whole exchange setup.** No Frontegg-side exchange client, no audience mappers (those were Model-A/Keycloak-native only).
2. `01-frontegg-jwks-backend.yaml` — static JWKS backend (443 + `policies.tls: {}`).
3. `04-frontegg-mcp-discovery.yaml` — route-level validation + MCP discovery (omit `mcp.provider`; the enum only accepts `Auth0`/`Keycloak`, verified live).

The exchange request the gateway STS expects (from the live run): `subject_token_type`
must be `urn:ietf:params:oauth:token-type:jwt` (the STS rejects `access_token`).

`02-`/`03-` (the IdP-native elicitation Secret + policy) are **not needed for Frontegg**
in this model and are kept only as a record of the Model-A shape.

## Confirm before applying

From the Frontegg portal (**Environment → Authentication → SSO → Identity Provider →
OpenID Connect Endpoints**):
- **Issuer** — the `iss` your hosted-login access tokens carry.
- **JWKS URI** — typically `https://<subdomain>.frontegg.com/.well-known/jwks.json`; verify.
- Set the `aud` you want via Frontegg's JWT claims config so the validator's audience check lines up.

## Live findings (demo account, 2026-06-16)

Provisioned automatically via `setup-frontegg.sh` against the demo tenant:

- Host `app-0nieh7hz8iun.frontegg.com`; issuer `https://app-0nieh7hz8iun.frontegg.com`;
  JWKS `.../.well-known/jwks.json` (RS256); token endpoint `.../oauth/token`.
- **`grant_types_supported` DOES include `urn:ietf:params:oauth:grant-type:token-exchange`** —
  so Frontegg supports RFC 8693 natively too, not only via the gateway STS. (My first
  answer said it didn't; that was from Frontegg's generic blog, not the live discovery doc.)
- Created tenant `solo-demo`, personas `alice` (Admin), `bob`/`carol` (ReadOnly), verified, passwords set; env switched to `EmailAndPassword`.

**Frontegg E2E proven live (captured 2026-06-16)** via `run-frontegg-e2e.sh`:
a real Frontegg-issued token (`iss: https://app-0nieh7hz8iun.frontegg.com`, RS256)
was validated against Frontegg's live JWKS by the gateway STS, which minted the
exchanged token:
```
subject: Frontegg token  ->  iss: enterprise-agentgateway...:7777
                              sub: b058b3e4-... (preserved)
                              aud: mcp-downstream (re-scoped)   RS256
```
STS validators were repointed to Frontegg via `frontegg-tokenexchange-values.yaml`
(`helm upgrade --reuse-values`).

**Human-sub caveat:** the captured `sub` is a tenant M2M client, not `alice`. This
hosted-login environment disables the embedded password-login API (`ER-01182`), so a
human `sub=alice` token must come from the hosted-login OAuth flow (browser) rather than
the API. The personas (alice/bob/carol) exist and show **Activated** in the portal; the
block is the login *method*, not activation. Minting Alice via hosted login and POSTing
that token to the STS runs the identical path — `sub` would then be Alice's id.

Secrets + discovered endpoints live in the gitignored `secrets/frontegg.keys` (never committed).
