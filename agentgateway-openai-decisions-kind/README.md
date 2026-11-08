# Classify support tickets with the OpenAI Decisions API through agentgateway

Solo Enterprise for agentgateway only. Standalone kind cluster `openai-decisions`.

Read [the lab page](index.html) for the four-part walkthrough: what Decisions is, when to use it, gateway setup, then live tests. The page shows individual commands and complete manifests. No OSS edition is included.

The companion blog post is [What the OpenAI Decisions API is for, and how to run it through agentgateway](../blog/openai-decisions/index.html).

## Entry point

Prerequisites: Docker, kind, kubectl, Helm, curl, jq, Python 3, ripgrep. Set `OPENAI_API_KEY` and `AGENTGATEWAY_LICENSE_KEY` in `~/.solo/secrets.env` (or set `SECRETS_FILE`). Never commit credentials.

```bash
./scripts/quick.sh up
./scripts/quick.sh test
```

`up` refuses an existing cluster. `test` writes `evidence/`, validates two synthetic tickets and model-labelled token metrics. It stops only its own temporary port-forward and leaves the cluster running. Calls use the configured OpenAI account.

For manual calls:

```bash
kubectl --context kind-openai-decisions -n agentgateway-system port-forward deployment/agentgateway-proxy 18091:80 15091:15020 --address=127.0.0.1
```

Then use the two curls on the page. No OpenAI credential goes in a client request.

Only after review, explicitly remove this lab:

```bash
CONFIRM_TEARDOWN=openai-decisions ./scripts/quick.sh teardown
```

## Version verification

Both Enterprise charts are pinned to `v2026.10.2`. The shipped `v2026.10.0` backend CRD rejects `SystemOne`; `v2026.10.2` accepts the full map. Validate manifests with `kubectl --context kind-openai-decisions apply --dry-run=server -f yaml/gateway.yaml -f yaml/backend.yaml -f yaml/httproute.yaml`. Helm values are from the shipped chart, backend fields from the official Solo Decisions guide and shipped CRD. Request question fields are from the official OpenAI Decisions guide. Guardrails and `prompts` do not apply to Decisions/SystemOne.
