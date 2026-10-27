# Bank refunds with A2A agents and gateway credential injection

Runnable code for the [bank refund lab](https://mastertheagent.com/solo/trustusbank-agent-refund-kind/).
Six declarative kagent agents investigate failed payments through A2A and MCP.
Agentgateway checks the caller, enforces a GBP 2,000 autonomous limit and adds
the bank credential on MCP-to-bank egress. Sarah requests a larger refund and
confirms the native Approve card in her own manager conversation.

The bank, fraud vendor and payment records are synthetic. No money moves.
Anthropic model calls are real and use the API key supplied during setup.

## Requirements

- Docker, kind, kubectl, Helm and Python 3 with PyYAML.
- Access to the Solo Istio image registry.
- Valid Solo Enterprise for Istio, agentgateway and kagent/management licences.
- An Anthropic API key.
- Enough local resources for Istio, gateway waypoints, six agent runtimes,
  PostgreSQL, the Solo UI, ClickHouse, Keycloak and Vault.

This is an **Enterprise-only** lab. It uses Solo Istio Enterprise waypoints,
Solo STS, kagent Enterprise OIDC and AccessPolicy. The `yaml-oss/` directory is
an untested illustrative subset, not an OSS edition of the complete use case.

## Install

Clone this directory from `tjorourke/solo-labs`, or work from the canonical
`solo-demos` repository. There is no dependency on the private staff suite.

Create a sourceable file outside the checkout, readable only by you:

```bash
mkdir -p "$HOME/.config/solo"
cat > "$HOME/.config/solo/refund-lab.env" <<'EOF'
SOLO_ISTIO_LICENSE_KEY='YOUR_SOLO_ISTIO_LICENCE'
AGENTGATEWAY_LICENSE_KEY='YOUR_AGENTGATEWAY_LICENCE'
SOLO_LICENSE_KEY='YOUR_KAGENT_AND_MANAGEMENT_LICENCE'
ANTHROPIC_API_KEY='YOUR_ANTHROPIC_API_KEY'
EOF
chmod 600 "$HOME/.config/solo/refund-lab.env"
export SECRETS_FILE="$HOME/.config/solo/refund-lab.env"
cd trustusbank-agent-refund-kind
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install PyYAML
bash scripts/quick.sh up
```

The scripts create and mutate only the standalone `kind-trustusbank-lab`
cluster. They do not use or alter `mesh1`, `mesh2` or the staff console.
Secrets are created from stdin, not embedded in checked-in manifests.
The kagent database uses kind's standard local-path provisioner.

Keep these two forwards open in separate terminals:

```bash
bash scripts/ui-forward.sh kagent
# http://refund-lab.localhost:19380

bash scripts/ui-forward.sh keycloak
# http://refund-idp.localtest.me:19580
```

Chrome resolves the UI's `.localhost` name to loopback and treats it as a secure
context, so browser crypto APIs work over local HTTP. The IdP's `localtest.me`
name also resolves to loopback. Distinct hostnames and ports keep this lab's
browser sessions separate from other local demos. Keycloak's issuer
also resolves inside the cluster through the lab's CoreDNS rewrite and issuer
Service port. HTTP, fixture passwords and the Vault dev server are lab settings;
the article explains the production changes.

## People and agents

All fixture passwords are `password`. Use separate browser profiles or sign
out between personas.

| Person | IdP group | Agent |
| --- | --- | --- |
| Carol | `customer-service` | `customer-service-assistant` |
| Bob | `payments-ops` | `payments-assistant` |
| Sarah | `payment_mgmt` | `payments-manager` |
| Alice | `security-ops` | Applies the scoped kill-switch policy |

Agent URLs start with:

```text
http://refund-lab.localhost:19380/ke/agents/trustusbank-lab/bank/
```

Append the agent name and `/`. The three specialist agents are called by the
assistants over A2A, rather than directly by employees.

## Walk through the use case

Start with clean mock receipts and new chats:

```bash
bash scripts/reset-receipts.sh
```

1. **Carol, customer-service-assistant:**

   > A customer says payment PAY-7781 failed this morning and the money has left their account. What happened?

   Expect Morgan Taylor, GBP 1,250, FAILED, DEBITED and a beneficiary bank timeout.

2. **Carol, payments-assistant:**

   > Please refund GBP 1,250 to the customer for PAY-7781.

   The agent waypoint refuses this access. This build can leave an empty chat
   title after a refusal; the gateway trace is the lasting denial record.

3. **Bob, payments-assistant:**

   > Look into PAY-7781 for me. The customer was charged but the merchant says nothing arrived.

   Inspect the customer, fraud and refunds specialist child calls. Investigation
   alone must not issue a refund.

4. **Bob, in that payments conversation:**

   > Refund the GBP 1,250 to the customer for PAY-7781.

   Expect an actual bank receipt with `credential_valid: true` and refunds-agent
   as the delegated actor.

5. **Bob:**

   > The customer has a second failed transfer, PAY-7790 for GBP 25,000. Arrange the refund.

   This is another payment for Morgan Taylor. The autonomous call exceeds GBP
   2,000 and is refused. Pass the payment reference and findings to Sarah manually.

6. **Sarah, payments-manager in her own browser session:**

   > Please arrange a GBP 25,000 refund for PAY-7790. Independently check the customer, fraud and payment records, then prepare the refund for my approval.

   Her assistant independently retrieves the records and pauses at the native
   `refund_payment_with_approval` card. Check PAY-7790 and 25000, then click
   **Approve**. Sending the prompt is the request, not the approval. **Reject**
   does not issue a refund. Bob cannot submit Sarah's confirmation.

7. **Bob, back in his original conversation:**

   > Has Sarah approved the refund for PAY-7790? Check the refund status.

   This is a read-only receipt lookup, not another refund instruction.

8. **Alice, then Bob:**

   ```bash
   bash scripts/killswitch.sh on
   ```

   > Another customer's GBP 900 payment PAY-7795 failed. Refund it.

   Bob's assistant stays available, but refunds-agent execution is refused.

9. **Alice, then Bob:**

   ```bash
   bash scripts/killswitch.sh off
   ```

   > Try PAY-7795 again.

   Inspect the issued receipt and the separate gateway/agent traces.

## How the agents were built

There is no custom orchestrator or approval queue. `yaml/agents.yaml` contains
six `kagent.dev/v1alpha2` declarative Agent resources and three RemoteMCPServers.
They share a ModelConfig pointing at the gateway's OpenAI-compatible model
endpoint. `tools[].type: Agent` enables the assistants' A2A calls; specialist
`McpServer` tools use the gateway URLs. Each agent receives its own waypoint.

| Source | Purpose |
| --- | --- |
| `yaml/agents.yaml` | Six agents, model configuration, A2A skills, MCP tools and manager `requireApproval` |
| `yaml/access.yaml`, `yaml/agent-identity.yaml` | IdP groups, native agent access and verified onward identity |
| `yaml/realm-bank.json` | Synthetic people, groups and group-derived `may_act.sub` grants |
| `yaml/payments.yaml` | Stateless Payments MCP backend, delegated-identity checks and GBP 2,000 traffic-phase limit |
| `yaml/core-bank.yaml`, `yaml/egress.yaml` | Bank route, authorised MCP workload and explicit egress credential injection |
| `yaml/payments-lockdown.yaml` | Strict mesh paths; no direct tool/bank bypass |
| `scripts/*_mcp.py`, `scripts/bank_data.py` | Synthetic MCP tools and records, deployed from ConfigMaps |
| `scripts/core_bank.py` | Mock bank, idempotent receipts and Vault credential validation |

The native runtime performs STS exchange. A2A forwards the original human
bearer; the specialist's MCP token has one actor. Do not infer a nested
assistant → specialist actor chain that is not present.

## Credentials and production scope

The agent and MCP pod specs reference no downstream provider/bank Secrets.
They still use short-lived identities, and kagent retains human request
headers in its session store. The model string in agent pods is only a
non-authenticating placeholder.

The lab creates a Vault token, stages it in `core-bank-key`, and the gateway
adds Authorization on `/core` egress. The mock bank validates the token with
Vault per request. `scripts/04-vault.sh` demonstrates revocation and
`scripts/renew-core-key.sh` updates the Secret without restarting the gateway.
This is a synthetic bank credential, not a claim that Vault can revoke every
real bank's API key. VSO, tenant isolation and a production bank integration
are recommendations in the article, not installed components here.

Keep the stateless MCP backends and disabled Anthropic parallel tool use on
these pinned builds. The native Python MCP discovery path has shown an
intermittent timeout; a completed answer saying records are unavailable is
not success. `quick.sh wake` verifies the actual customer record.

## Verify, reset and remove

```bash
bash scripts/quick.sh test       # Native story, approval, negative controls and amount boundaries
bash scripts/quick.sh wake       # Read-only readiness, may renew an expired bank credential
python3 scripts/reset.py         # Scoped history, pending-task, receipt and trace reset
bash scripts/quick.sh teardown   # Deletes only the standalone trustusbank-lab cluster
```

`test` confirms native approval **as Sarah** for automated validation. For a
manual demonstration, use the native UI button yourself. The verifier writes
redacted evidence and trace IDs under `/tmp/trustusbank-*`; never publish raw
kagent REST session responses, which contain saved bearer headers.

The reset clears only bank data on this standalone context. It retains the
installed agents, policies, IdP groups and platform, and verifies removal.
New controller discovery can produce fresh technical traces afterwards.
Use teardown when finished to release the temporary cluster's resources.
