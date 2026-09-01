# One gateway, many AWS accounts: AgentCore behind a single agentgateway

A single enterprise agentgateway on kind invokes AWS Bedrock AgentCore runtimes in
two different AWS accounts and two different regions: one `AgentgatewayBackend` per
runtime, each with `spec.aws.agentCore.agentRuntimeArn` (the foreign ARN) and
`spec.policies.auth.aws.assumeRole` (the per-account STS hop). AgentRegistry
Enterprise deploys the agents (source mode, no ECR) but its Runtimes carry no
`gatewayRef`, so the registry never writes gateway config or gateway IAM. OpenTofu
provisions every role in both accounts. CloudTrail in each account records the
caller's Keycloak username on every AssumeRole session. The registry's
one-account-per-automated-binding refusal ("bound runtimes resolve to multiple AWS
accounts") is captured live and reverted.

Full write-up: `index.html` (published on the site).

## Prerequisites

- Two AWS accounts with CLI profiles (admin in the "shared services" account A; the
  account B profile only needs IAM create/attach rights).
- `tofu`, `kind`, `kubectl`, `helm`, `docker`, `aws`, `jq`, `gh` (authenticated),
  `arctl` (v2026.6.1), `gcloud` (for the Solo chart registry).
- `SOLO_LICENSE_KEY` (enterprise agentgateway + AgentRegistry 2026.8.0), or
  `SECRETS_FILE=/path/to/secrets.sh`.

## Run

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars   # your two profiles
export SOLO_LICENSE_KEY=...
./scripts/quick.sh up          # tofu + kind + Keycloak + AGW + AR + runtimes + agents + routes + invoke
./scripts/50-cloudtrail.sh     # per-caller AssumeRole evidence in BOTH accounts
./scripts/51-mismatch-demo.sh  # the live AWSAccountMismatch refusal; then: ... revert
./scripts/quick.sh teardown    # kind + AgentCore runtimes + tofu destroy
```

The numbered scripts run individually in order: `10-tofu`, `20-cluster`,
`21-keycloak`, `22-agentgateway`, `23-ingress`, `24-agentregistry`, `30-runtimes`,
`33-model-access`, `31-agents`, `32-wait-runtimes`, `40-gateway-config`,
`41-invoke`.

## Layout

- `tofu/` — both accounts: per-env module (AgentRegistryAccess role + invoke role +
  ExternalId), plus the two source-identity IAM users in account A.
- `scripts/` — numbered setup + proof scripts, `quick.sh` orchestrator.
- `yaml/portfolio-routes.yaml.tmpl` — the 4 backends, 4 routes, 2 JWT policies.
- `kind/cluster.yaml`, `yaml/keycloak/` — platform plumbing.
- `deploy/.env.tofu`, `deploy/.env.runtimes` — generated, gitignored, never commit.
