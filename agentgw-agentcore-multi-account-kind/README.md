# One gateway, many AWS accounts: AgentCore behind a single agentgateway

A single enterprise agentgateway on kind invokes AWS Bedrock AgentCore runtimes in
two different AWS accounts and two different regions: one `EnterpriseAgentgatewayBackend` per
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

- Two AWS accounts with CLI profiles. Account A ("shared services") needs admin.
  Account B needs IAM create **and delete** rights: creating an inline role policy
  takes `iam:PutRolePolicy`, but removing one takes `iam:DeleteRolePolicy`, and a role
  cannot be deleted while it still carries one. A permission set with create but not
  delete brings the lab up fine and then strands two roles at teardown.
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
./scripts/quick.sh teardown    # or ./scripts/teardown.sh — same thing
```

## Teardown

`scripts/teardown.sh` (what `quick.sh teardown` runs) removes everything, in the one
order that works. tofu owns the IAM users and access keys that are the only route into
the two portfolio accounts, so every non-tofu artefact has to go first:

1. the four AgentCore runtimes (billed per invocation)
2. their CloudWatch log groups
3. their SDK execution roles, which AgentCore creates and tofu never sees
4. their S3 source bundles (`bedrock-agentcore-codebuild-sources-*`)
5. `tofu destroy`, all IAM in both accounts
6. the kind cluster
7. the public GitHub repo `31-agents.sh` published, after asking
8. a verification pass that re-reads both accounts and **exits non-zero if anything is
   left**, rather than reporting what it merely attempted

Everything is scoped to this lab's own agents and runtimes, because these accounts are
shared with other labs: nothing is deleted by "everything in the region". Preview with
`TEARDOWN_DRY_RUN=1 ./scripts/teardown.sh`, skip the repo prompt with
`TEARDOWN_DELETE_REPO=1`, and note that deleting the repo needs
`gh auth refresh -h github.com -s delete_repo`.

Source mode clones the agents from a **public** GitHub repo that `31-agents.sh` creates
on your account, so teardown offers to delete it. Nothing else is left behind except
`AWSServiceRoleForBedrockAgentCoreRuntimeIdentity`, an empty AWS service-linked role
that costs nothing and is re-created on demand.

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
