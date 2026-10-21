# TrustUs Bank: an agent refund, start to finish

A customer phones about failed payment PAY-7781. Priya in payments-ops asks the
assistant to check it and refund the customer. A £1,250 refund completes; a
second £25,000 request waits for Priya's approval.

## Run

Requires Docker with `docker image save --platform`, kind, kubectl, Helm and
Python 3 with PyYAML. Set `SECRETS_FILE` to your sourceable secrets file,
containing `AGENTGATEWAY_LICENSE_KEY` and `ANTHROPIC_API_KEY`. The scripts pass
keys to Secrets through stdin.

```bash
bash scripts/quick.sh up
bash scripts/quick.sh test
bash scripts/ui-forward.sh kagent
# kagent agent view: http://localhost:18380
bash scripts/quick.sh teardown
```

Only `kind-trustusbank-lab` is used. Lab-authored resources pass a server dry-run
before apply. The bank and payment tools are mocks; no money moves. The console
calls these same capture scripts, in this order:

1. `capture-01.sh`: Priya signs in.
2. `capture-03.sh`: the assistant hands over the job.
3. `capture-05.sh`: the £1,250 refund goes through.
4. `capture-06.sh`: a larger refund waits for Priya.
5. `capture-rogue.sh`: a rogue agent copies the request and is refused.
6. `capture-kill.sh`: security stops one agent instance.
7. `capture-07.sh`: compliance checks the refund record.

Read [the walkthrough](index.html) for the commands and captured outputs.

## How it works

The ledger uses the native ADK confirmation mechanism from
`agentic-verdict-hitl-kind`: the same kagent ADK image `0.8.0-beta6`, Anthropic
model and A2A confirmation payload. The running image imports Google ADK
`1.25.0`. Its MCP toolset requires
confirmation for `refund_payment` above GBP 10,000. The capture proves no bank
write before approval, agent self-approval refusal and completion after Priya's
Keycloak-authenticated response.

The assistant and ledger have separate Kubernetes identities. Ledger exchanges
the delegated token with its own mounted token before calling the payment
tools. The gateway supplies the Vault-issued bank credential on egress; neither
agent mounts it. The evidence record joins the approved task context to the
gateway call and the mock bank result.

The single-node lab has a pre-provisioned local database volume, one DNS replica
and no dynamic volume provisioner. Optional gateway extensions are disabled.
Management UI 0.5.6 provides the policy views; its separate tracing collector
has zero replicas. kagent's UI remains linked from the presenter console.

## Gateway token exchange finding

On agentgateway v2026.10.0, gateway-driven `oauthTokenExchange.actorToken`
returned HTTP 502 with `unsupported token_type: N_A`. This lab exchanges directly
at STS. RFC 8693 treats prior actors as informational; the gateway adds the lab's
order and depth checks locally.
