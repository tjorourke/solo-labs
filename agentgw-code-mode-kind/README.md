# agentgw-code-mode-kind

agentgateway **code mode**: the same OpenAPI backend that would normally show up as
one MCP tool per operation is instead exposed as a single `run_code` tool whose
description is a generated TypeScript API. The client writes one JavaScript program
against that API; the gateway runs it in a sandbox, makes the upstream REST calls,
and returns only what the program returns.

A single, standalone kind cluster running Solo Enterprise for agentgateway with the
public Swagger petstore behind it in `toolMode: Code`.

## Why

Front a real API with MCP and you get a tool per operation. The whole catalogue
sits in the model's context every turn, and a job that lists, filters, looks up
detail and aggregates becomes one round trip per step with every intermediate
result passing through the model. Code mode collapses that to one tool, one
program, one round trip: the filtering and shaping happen in the gateway sandbox,
not in the model's context window.

`toolMode` has three settings (see `CLAUDE.md`):

- **Standard** (default) — one tool per operation.
- **Search** — `get_tool` / `invoke_tool` for progressive disclosure.
- **Code** — a single `run_code` tool. This lab.

## Bring it up

Standalone cluster. Needs an agentgateway license, plus an Anthropic key for the
Claude step:

```bash
export AGENTGATEWAY_LICENSE_KEY=...     # Solo Enterprise for agentgateway
export ANTHROPIC_API_KEY=sk-ant-...     # for ask-llm.sh
./scripts/quick.sh up
```

(The Solo charts are pulled from a Google Artifact Registry; `gcloud` must be
installed and authenticated — the scripts run `helm registry login` for you.)

## The OpenAPI ConfigMap

You don't hand-write the OpenAPI document — the API publishes its own. The lab
loads the petstore's published spec into a ConfigMap; that is the one command a
customer would run (`03-backend-route.sh` does exactly this, falling back to the
pinned `yaml/petstore-openapi.json` when the URL is unreachable):

```bash
kubectl create configmap petstore-openapi -n agentgateway-system \
  --from-file=schema=<(curl -s https://petstore3.swagger.io/api/v3/openapi.json) \
  --dry-run=client -o yaml | kubectl apply -f -
```

The spec has 19 operations; in code mode they all become the single `run_code`
tool. The MCP client never sees the ConfigMap or the spec.

## See it

```bash
./scripts/show-tools.sh        # the single run_code tool + its generated TypeScript API
./scripts/run-code.sh          # send JavaScript, get a small summary back (no LLM)
./scripts/ask-llm.sh "which categories have the most available pets?"   # Claude writes the JS
```

`show-tools.sh` lists the MCP tools: in code mode there is exactly one,
`run_code`, and its description is the contract — the rules for the JavaScript plus
all 19 petstore operations turned into typed `async` functions (`addPet`,
`findPetsByStatus`, `getPetById`, `placeOrder`, `getInventory`, and so on).

`run-code.sh` is the raw mechanic: it sends a program that lists available pets,
groups them by category and fetches a few in parallel, and prints the
`{ "success": … }` summary. Pass your own JS as an argument to experiment.

`observe.sh [debug|trace]` turns the gateway data-plane log level up at runtime
(via its admin endpoint, no restart) and tails the logs, so you can watch the
inbound `run_code` call and each upstream REST call it makes to the petstore;
it resets to `info` on exit.

`ask-llm.sh` hands Claude only `run_code` and a question in English; Claude reads
the generated API and writes the JavaScript itself.

## Status

Verified end to end live on kind (`v2026.5.2` chart): the backend is Accepted, the
gateway exposes a single `run_code` tool, a hand-written program and Claude both
drive it successfully, and the captured output is on the page. The public petstore's
write path (`addPet`) was returning `500` during capture, so the demo leans on the
read/aggregate operations — see `CLAUDE.md`.

## Reset / teardown

```bash
./scripts/quick.sh status      # pods, backend, gateway, route
./scripts/quick.sh teardown    # delete the cluster
```

## Notes

- Needs `docker`, `kind`, `kubectl`, `helm`, `gcloud`, and `uv` (runs the Python
  MCP client with its dependencies declared inline).
- Fully standalone — its own `code-mode` kind cluster, no dependency on any other
  lab.
- The local port-forward uses a high port (`18770`) on purpose; override with
  `MCP_LOCAL_PORT`.
- See `CLAUDE.md` for the verified CRD shapes, gotchas, and the end-to-end record.
