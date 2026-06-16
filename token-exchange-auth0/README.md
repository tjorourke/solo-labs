# Auth0 — token exchange (config mirror)

> **Status: config mirror, NOT live-tested.** Transcribed from the article's Auth0 section
> (https://www.masterthemesh.com/solo/token-exchange-idp-setup/#auth0). No Auth0 tenant was
> available to run it. Sample tenant host `acme.eu.auth0.com`.

Auth0 uses the generic RFC 8693 grant via `tokenExchange.elicitation` (IdP-native / Flow A).
Its quirk: Auth0 only stamps an `aud` when the client requests an API Identifier as the
audience. Point the install-time `subjectValidator`/`apiValidator` at
`https://acme.eu.auth0.com/.well-known/jwks.json`; tokens carry `iss = https://acme.eu.auth0.com/`
(trailing slash) and the API Identifier as `aud`.
