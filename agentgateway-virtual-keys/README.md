# Virtual keys, dimensions and budgets

Solo Enterprise for agentgateway **v2026.9.0**, Gateway API **v1.5.1**, optional
Solo UI management chart **0.5.7**, on kind. Enterprise-only because this lab uses
`EnterpriseAgentgatewayBudget` and `entBudgetEnforcement`.

The local OpenAI-compatible mock reports 100 input and 20 output tokens. Its
artificial price is $10,000 per million tokens: **$1.20 simulated spend per
request**. No requests reach a provider. No provider key or real spend is needed.

## Run

Prerequisites: Docker running, kind, kubectl, Helm, Python 3 and an exported
`AGENTGATEWAY_LICENSE_KEY`. Alternatively set `SECRETS_FILE` to a local shell
environment file (default `~/code/solo/secrets/secrets-envs.sh`). Allow additional
Docker memory for the UI's bundled ClickHouse (3 GiB default memory request).

Run from this directory:

```bash
bash scripts/quick.sh up
bash scripts/quick.sh ui
bash scripts/quick.sh test
bash scripts/quick.sh demo
bash scripts/quick.sh ui-forward
```

Open **http://localhost:18090/age/**. Leave the foreground port-forward running.
The UI uses the chart's evaluation auto-auth. Navigate to **Gateways**,
**Dimensions**, **Virtual Keys**, and **Cost Management → Budgets**.

`test` verifies silver/gold model permissions, 401s, independent key allowances, shared team blocking,
cost-centre Audit, labelled token metrics, a live budget increase, live model
repricing and key revocation. It compares gateway pod UIDs and restart counts.
It leaves Alice revoked, per-key allowance at 100,000 tokens, team allowance at
$50, and test rates at $20,000/million ($2.40/request).

`demo` restores all four keys and initial prices, replaces only this lab's
budgets (label `lab=virtual-keys`) with a fresh `virtual-keys-test-*` resource
name, then runs the initial enforcement sequence. Alice exhausts 250 tokens;
engineering crosses $5; the cc-product/dev Audit budget logs overages. This is
the screenshot-ready state. Neither command clears ClickHouse history. Fresh
budget IDs avoid reusing old Redis counters. Catalogue reload can take up to
180 seconds in the checks.

## Manual requests

For interactive alias testing, run `bash scripts/quick.sh models`. It restores
all keys, verifies the access matrix, and creates fresh larger allowances
(100,000 tokens per key, $50 Engineering spend). Alice/Carol can use `silver`;
Bob/Dave can use `silver` and `gold`. Both aliases use the local mock, which
echoes `resolved-silver` or `resolved-gold` after the gateway rewrites the model.
The original `virtual-key-demo` model remains allowed for all four keys.

`yaml/model-access.yaml` checks `json(request.body).model in apiKey.allowedModels`
before alias rewriting. Invalid/missing model input, raw target names, unknown
models and a spoofed tier header are tested as denied. Return to the small-budget
screenshot state with `bash scripts/quick.sh demo`.

```bash
# Separate terminal
bash scripts/quick.sh forward

curl -i http://localhost:18080/v1/chat/completions \
  -H 'Authorization: Bearer vk-demo-alice-not-for-production' \
  -H 'Content-Type: application/json' \
  -d '{"model":"virtual-key-demo","messages":[{"role":"user","content":"hello"}]}'
```

Keys follow the fixed public pattern `vk-demo-<user>-not-for-production` for
alice, bob, carol and dave. Use random credentials in real deployments. After
`demo`, Alice/Carol return 429, while Dave still has allowance in research.

## Configuration

- `yaml/virtual-keys.yaml`: SHA-256 hashes, metadata and per-key model allowlists.
- `yaml/auth-budget.yaml`: selects the key ConfigMap, enables budgets and adds metrics/log fields.
- `yaml/model-access.yaml`: per-key model authorisation and silver/gold aliases.
- `yaml/model-catalog.yaml`: artificial prices for the fixture and resolved models.
- `yaml/values.yaml`: group/user hierarchy, virtualKey, costCenter, environment.
- `yaml/budgets.yaml`: per-key Tokens, engineering USD Block, cc-product/dev Audit.
- `yaml/gateway.yaml`: Gateway, route, backend and catalogue parameters reference.
- `yaml/mock.yaml`: deterministic local LLM fixture.
- `yaml/ui-values.yaml` and `yaml/telemetry.yaml`: optional UI and trace collection.
- `scripts/test.py`: live tests and screenshot-ready demo mode.

ConfigMaps accept `keyHash`, selected using `configMapSelector`. Secrets remain
supported with `key` or `keyHash`. JSON metadata is exposed directly as
`apiKey.*`. Do not give the key ConfigMap the Gateway's name: AGW creates its
own ConfigMap with that name.

Budget checks happen before admission; usage is debited after responses, so
crossing requests and concurrent calls can overshoot. The rate limiter fails
open if unavailable. Unpriced models add nothing to USD usage. Redis enforcement
counters and ClickHouse telemetry history are separate stores.

Every script kubectl/Helm call uses explicit context `kind-agw-virtual-keys`.
kind creation changes the current kubectl context. `CLUSTER`, `AGW_VERSION`,
`GWAPI_VERSION`, `MGMT_VERSION`, `PORT`, `UI_PORT` are optional overrides;
overrides are not implied to have passed the recorded validation.

## Cleanup

Stop port-forwards with Ctrl-C, then `bash scripts/quick.sh teardown`. It deletes
only the selected lab kind cluster and checks it is gone. Ephemeral UI history
is deleted with the cluster. Full walkthrough: [index.html](index.html).
