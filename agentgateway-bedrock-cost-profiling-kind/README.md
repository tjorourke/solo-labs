# agentgateway-bedrock-cost-profiling-kind

Front Amazon Bedrock with Solo Enterprise for agentgateway and attribute LLM
cost **per team**. Each team gets its own Bedrock **application inference
profile** (cost-allocation tagged). One `AgentgatewayBackend` with the `bedrock`
provider and the model left unset serves every team, because the model comes
from each request as that team's profile ARN. Usage is then attributable per
team in two places:

- **In the gateway, live** — `agentgateway_gen_ai_client_token_usage` splits by
  team via the `gen_ai_request_model` label (the team's profile ARN).
- **In AWS, in dollars** — the profile's cost-allocation tag breaks out cost per
  team in AWS Cost Explorer.

The page (`index.html`) explains what Bedrock Mantle is and how it relates,
inference profiles and ARNs, the Converse path, the AWS setup, and the Solo
deployment.

## Prerequisites

- `kind`, `kubectl`, `helm`, `jq`, `aws`, `docker`
- A Solo Enterprise agentgateway license: `export AGENTGATEWAY_LICENSE_KEY=...`
  (or `SECRETS_FILE=/path/to/secrets.sh`).
- **Live AWS access** to an account with **Bedrock model access** for the base
  model in `REGION` (default `us-east-1`), and enough daily token quota to run a
  few requests. Log in first: `aws sso login --profile <your-profile>`.
- `AWS_PROFILE` must point at that account. The lab does not hardcode a profile;
  it uses whatever `AWS_PROFILE`/`SECRETS_FILE` provide. The profile may be SSO
  (temporary creds) or a static IAM user — the credential Secret handles both.

## Run

```bash
export AWS_PROFILE=<your-profile>
aws sso login --profile "$AWS_PROFILE"
export AGENTGATEWAY_LICENSE_KEY=...        # or rely on SECRETS_FILE

./scripts/quick.sh up          # cluster + agentgateway + per-team profiles + backend + smoke
./scripts/quick.sh test        # asserts 200s + a per-team metric series
./scripts/quick.sh teardown    # deletes the kind cluster and the AWS profiles
```

Or step by step: `01-cluster.sh` → `02-agentgateway.sh` → `03-aws-profiles.sh`
→ `04-backend.sh` → `05-test.sh` → `06-metrics.sh`.

## Pattern A — select the team from its JWT (ARN off the client)

`04`/`05` let the client send the profile ARN as the model (simplest). For
production you don't want clients carrying ARNs. `07-jwt-teams.sh` adds the
identity layer: an RS256 inline-JWKS `jwtAuthentication` policy in the
`PreRouting` phase with a CEL transformation that projects the signed `team`
claim into the `x-team` routing header (overwriting any client value), plus one
backend per team with the model pinned to that team's profile ARN. Routing is
driven by the claim; the client sends only its token.

```bash
bash scripts/07-jwt-teams.sh                 # JWT + PreRouting team→x-team + per-team backends/routes
TOKEN=$(./scripts/mint-token.sh finance)
curl localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
# gateway projects team=finance → x-team:finance → bedrock-finance → finance ARN
```

Verified live: no token → 401; `finance` token (no team header) → 200 on the
finance ARN; `engineering` likewise; `finance` token while the client sends
`x-team: engineering` → still finance (the PreRouting transformation overwrites
the header, so it cannot be spoofed). The RS256 private key lives in `.gen/`
(gitignored).

Change the teams with `TEAMS="finance engineering risk"`; change the model with
`BASE_MODEL=...`; change the region with `REGION=...`.

## Version

Built and verified on Solo Enterprise for agentgateway **v2026.5.1** (pinned in
`scripts/lib.sh`). Re-validate and bump when moving to a newer build.

## E2E

Registered in `labs.manifest.json` as `requires: ["solo-license","aws"]`,
`skipByDefault: true`. The E2E runner (`scripts/labs-e2e.sh`) fails fast before
building anything if a queued lab needs AWS and there is no live session. Run it
explicitly:

```bash
scripts/labs-e2e.sh --only agentgateway-bedrock-cost-profiling-kind
```

`results/` (profile ARNs, metrics) is gitignored — it carries your AWS account id.
