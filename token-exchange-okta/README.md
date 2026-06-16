# Okta — token exchange (config mirror)

> **Status: config mirror, NOT live-tested.** Transcribed from the article's Okta section
> (https://www.masterthemesh.com/solo/token-exchange-idp-setup/#okta). No Okta tenant was
> available to run it. Sample org `acme.okta.com`, custom auth-server id `aus1a2b3c4D5e6F7g8`.

Okta uses the generic RFC 8693 grant via `tokenExchange.elicitation` (IdP-native / Flow A),
but you MUST use a **custom authorization server** (`/oauth2/<id>/...`), never the org
server. Point the install-time validators at the custom server's keys
(`https://acme.okta.com/oauth2/aus1a2b3c4D5e6F7g8/v1/keys`); tokens carry
`iss = https://acme.okta.com/oauth2/aus1a2b3c4D5e6F7g8`.
