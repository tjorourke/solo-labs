# Claude Code on a non-Anthropic model, through agentgateway

Serve the Anthropic Messages API with Solo Enterprise for agentgateway and
translate it to an OpenAI model behind the gateway. Point Claude Code at it,
keep the model credential in the cluster, and put JWT authentication and a CEL
authorization rule in front. One kind cluster.

The gateway serves `/v1/messages` (the Anthropic Messages API). The
`ai.routes` map reads that path as Messages input, and because the backend's
provider is OpenAI, agentgateway translates the request to OpenAI
chat-completions on the way in and the reply back to Anthropic Messages on the
way out. Claude Code never knows the model is not Anthropic.

## Prerequisites

- `kind`, `kubectl`, `helm`, `docker`, `openssl`, `xxd`, `jq`, and an
  authenticated `gcloud` for the public chart registry.
- `AGENTGATEWAY_LICENSE_KEY` — a Solo Enterprise agentgateway license.
- `OPENAI_API_KEY` — the backend model credential. Becomes a cluster Secret and
  nothing else. May also be read from a file via `OPENAI_KEY_FILE`.

## Run

```bash
export AGENTGATEWAY_LICENSE_KEY="your-license-key"
export OPENAI_API_KEY="sk-..."           # or: echo sk-... > "$OPENAI_KEY_FILE"
./scripts/quick.sh up                    # cluster, agentgateway, backend, route, rbac

./scripts/quick.sh demo                  # port-forward to localhost:8080  (one shell)
./scripts/quick.sh test                  # the three scenarios            (another shell)
```

`SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh up` sources both keys from
a file instead of the environment.

## The three scenarios

| Request | Result | Why |
|---|---|---|
| No `Authorization` header | 401 | JWT required (mode `Strict`) |
| JWT `team=marketing` | 403 | CEL rule allows only `team=data-platform` |
| JWT `org=acme`, `team=data-platform` | 200 | Translated to OpenAI, answered by `gpt-4o-mini`, returned in Anthropic format |

```bash
TOKEN=$(./scripts/mint-token.sh)         # authorized
BAD=$(./scripts/mint-token.sh marketing) # wrong team -> 403
```

## Point Claude Code at it

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
export ANTHROPIC_API_KEY=$(./scripts/mint-token.sh)   # the gateway JWT
```

## Swap in your own model

Keep the backend, route, and policy. In `yaml/backend.yaml`, point `host` and
`port` at your in-cluster OpenAI-compatible server (vLLM, Ollama), or change the
provider block. The `ai.routes` translation and the client contract stay the
same; the credential stays in the Secret.

## Files

```
kind/cluster.yaml        single kind cluster
yaml/gateway.yaml        Gateway (gatewayClassName: enterprise-agentgateway)
yaml/backend.yaml        AgentgatewayBackend: provider openai + ai.routes Messages
yaml/httproute.yaml      /v1/messages -> openai backend
yaml/rbac-policy.yaml    EnterpriseAgentgatewayPolicy: JWT Strict + CEL authorization
scripts/01-cluster.sh    cluster + Gateway API CRDs
scripts/02-agentgateway.sh   enterprise agentgateway install + Gateway
scripts/03-backend.sh    OpenAI Secret + backend + route
scripts/04-rbac.sh       RS256 keypair + inline JWKS + policy
scripts/mint-token.sh    mint an RS256 JWT (org/team/llms claims)
scripts/demo.sh          port-forward
scripts/test.sh          the three scenarios
scripts/quick.sh         orchestrator: up | demo | test | status | teardown
```

## Teardown

```bash
./scripts/quick.sh teardown
```
