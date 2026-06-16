# Microsoft Entra ID — token exchange (config mirror)

> **Status: config mirror, NOT live-tested.** These files are transcribed from the
> published article's Entra section
> (https://www.masterthemesh.com/solo/token-exchange-idp-setup/#entra). No Entra tenant
> was available to run this end to end. The CRD/Helm shapes are verified against the
> schema; the tenant/client UUIDs are illustrative samples. Verify issuer/JWKS against
> your own tenant before relying on it.

Entra is the one IdP that does **not** use the generic RFC 8693 grant. It uses
Microsoft's on-behalf-of (`jwt-bearer`) flow via the native `tokenExchange.entra` block,
and the gateway proxies the exchange out to Microsoft's token endpoint (`mode: ExchangeOnly`).

Files: `01-jwks-backend.yaml` (login.microsoftonline.com), `02-secret.yaml` (client secret
only — the rest is inline on the policy), `03-tokenexchange-values.yaml` (install-time
validators → Entra discovery keys), `04-exchange-policy.yaml` (the OBO policy). The MCP
`EnterpriseAgentgatewayBackend` it targets (`acme-mcp-backend`) is the shared one from the
article, see `../token-exchange-keycloak-kind/` for a live MCP backend example.
