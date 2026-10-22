# TrustUs Bank: refunding a customer with an AI agent

A customer phones about failed payment PAY-7781. The payments team's assistant,
which Bob uses, checks the payment and refunds the customer. A £1,250 refund completes; a
second £25,000 request waits for Bob's approval.

## Run

Requires Docker with `docker image save --platform`, kind, kubectl, Helm and
Python 3 with PyYAML. Set `SECRETS_FILE` to your sourceable secrets file,
containing `SOLO_LICENSE_KEY`, `AGENTGATEWAY_LICENSE_KEY` and `ANTHROPIC_API_KEY`. The scripts pass
keys to Secrets through stdin.

```bash
bash scripts/quick.sh up
bash scripts/quick.sh test
bash scripts/ui-forward.sh kagent
# Second terminal:
bash scripts/ui-forward.sh keycloak
# Third terminal:
bash scripts/ui-forward.sh management
```

Only `kind-trustusbank-lab` is used. Lab-authored resources pass a server dry-run
before apply. The bank and payment tools are mocks; no money moves.

Open <http://localhost:18380/ke/agents/trustusbank-lab/bank/payments-assistant/>. Keycloak redirects
to `keycloak.localtest.me:18580`. Sign in as **bob / password** (lab-only).
Bob's identity is carried by kagent Enterprise. Sign-in is step 1 and has no chat
prompt. The assistant belongs to the payments team, rather than to Bob personally.
The console at `/trustusbank-agent-refund` supplies the exact prompts to copy
into the model-backed assistant. It uses the real STS, ledger A2A and gateway
MCP path. Review the native approval card and click Approve as Bob for the
£25,000 refund. Expand the tool cards and Results to inspect the bank receipts.

The security and compliance steps are operator commands:

```bash
bash scripts/capture-rogue.sh
bash scripts/capture-kill.sh
bash scripts/capture-07.sh
```

The instance-switch check restores traffic after proving the selected pod is
blocked. Evidence joins the latest UI-approved native ledger task to the gateway
log and saves `/tmp/trustusbank-evidence.json`.

The automated capture entry points remain available for terminal validation:

1. `capture-01.sh`: Bob signs in.
2. `capture-03.sh`: the assistant hands over the job.
3. `capture-05.sh`: the £1,250 refund goes through.
4. `capture-06.sh`: a larger refund waits for Bob.
5. `capture-rogue.sh`: a rogue agent copies the request and is refused.
6. `capture-kill.sh`: security stops one agent instance.
7. `capture-07.sh`: compliance checks the refund record.

Read [the walkthrough](index.html) for the commands and captured outputs.

When finished with the lab, `bash scripts/quick.sh teardown` deletes only this
lab’s kind cluster. Keep it running between presenter steps.

## How it works

The ledger uses the native ADK confirmation mechanism from
`agentic-verdict-hitl-kind`: the same kagent ADK image `0.8.0-beta6`, Anthropic
model and A2A confirmation payload. The running image imports Google ADK
`1.25.0`. Its MCP toolset requires
confirmation for `refund_payment` above GBP 10,000. The capture proves no bank
write before approval, agent self-approval refusal and completion after Bob's
Keycloak-authenticated response.

The assistant and ledger have separate Kubernetes identities. Ledger exchanges
the delegated token with its own mounted token before calling the payment
tools. The gateway supplies the Vault-issued bank credential on egress; neither
agent mounts it. The evidence record joins the approved task context to the
gateway call and the mock bank result.

The controller and UI run Solo Enterprise for kagent `0.5.11`, with upstream
agent runtime `0.10.3` and browser-agent Google ADK `1.38.0`. The native approval
card gates `approve_delegated_refund`, then resumes the ledger's confirmation.
The runtime adapters remain: user context must be set before task reads, ADK
requires its confirmation check, and Enterprise callbacks need the explicit
`user_id` query. The ledger's older SDK uses a separate request-scoped callback
adapter. Authentication and task ownership checks remain enabled.

`enterprise-oidc.py` configures a public PKCE frontend client and confidential
backend client in the existing bank realm. `skipOBO: true` preserves the original
Keycloak user token because the bank bridge performs the real Solo STS exchange.
Client secrets and licence/model keys are passed through stdin. The licence
variable is `KAGENT_ENT_LICENSE_KEY`, defaulted from `SOLO_LICENSE_KEY`.

Version `0.5.11` is deliberate: Solo's current docs list it as latest; it includes
the light UI introduced in `0.5.7` and the `may_act` token classification fix in
`0.5.9`. Commit `ecf5eef50` records the older BYO callback failure. This lab fixes
that callback's missing user context, rather than reverting to OSS or `0.4.3`.

The single-node lab has a pre-provisioned local database volume, one DNS replica
and no dynamic volume provisioner. Optional gateway extensions are disabled.
Management UI `0.5.11` provides both the kagent and agentgateway views. Tracing
is enabled with sampler `always_on`, OTLP/gRPC to the management collector in
`agentgateway-system`, `products.kagent.enabled=true` and trace ingestion enabled.
ClickHouse stores the spans. The real refund trace is linked from the console
and guide. Istio stays OSS `1.30.4`; Keycloak and Vault are not Solo products.

## Migration checkpoint

The original OSS state is saved locally under `/tmp/trustusbank-oss-snapshot/`,
including a database dump. Local tag `trustusbank-oss-working` was not pushed.
`/tmp/trustusbank-rollback.sh` is an explicit recovery script and was not run.
Enterprise uses a separate retained local database volume, preserving the old
OSS database. `10-kagent-enterprise.sh` installs the Enterprise charts in place;
it does not recreate the kind cluster or change Istio.

Sources: [installation](https://docs.solo.io/kagent/0.5.x/install/install-kagent/),
[Keycloak](https://docs.solo.io/kagent/0.5.x/security/idp/keycloak/),
[tracing](https://docs.solo.io/kagent/0.5.x/observability/tracing/),
[release notes](https://docs.solo.io/kagent/0.5.x/reference/changelog/kagent-ent/).

## Gateway token exchange finding

On agentgateway v2026.10.0, gateway-driven `oauthTokenExchange.actorToken`
returned HTTP 502 with `unsupported token_type: N_A`. This lab exchanges directly
at STS. RFC 8693 treats prior actors as informational; the gateway adds the lab's
order and depth checks locally.
