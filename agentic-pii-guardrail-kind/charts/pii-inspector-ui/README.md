# pii-inspector-ui — Helm chart

Drop-in side-by-side **prompt / what-the-LLM-saw / what-came-back** UI for any
agentgateway LLM route. Use it to validate built-in `promptGuard` masks, custom
[Guardrail Webhook](https://docs.solo.io/agentgateway/2.1.x/llm/guardrail-api/)
implementations, or both at once.

Two modes:

| Mode | Set `webhook.url` | What you see |
|---|---|---|
| **With webhook** (recommended for guardrail dev) | yes — your webhook's `/events` admin endpoint | Three columns: original prompt, what the LLM actually received after redaction, what came back. Includes a per-request audit row with the matched patterns. |
| **Generic gateway** (no webhook implemented yet) | no | Two columns: prompt, response. Useful as a smoke-test client for an LLM route — also tells you when the gateway returns 4xx (`Reject` from a built-in regex shows up as the raw 403 body). |

Two LLM wire formats:

| `agw.format` | Gateway path | Request body shape | Response parsed from |
|---|---|---|---|
| `anthropic-messages` (default) | `/v1/messages` | Anthropic native | `content[].text` blocks |
| `openai-chat` | `/v1/chat/completions` | OpenAI Chat Completions | `choices[].message.content` |

The same image binary speaks both — flip the env var, point at the right path.

## Source

- Image source: [solo-demos/agentic-pii-guardrail-kind/src/inspector-ui](https://github.com/tjorourke/solo/tree/main/agentic-pii-guardrail-kind/src/inspector-ui)
- Chart source: [solo-demos/agentic-pii-guardrail-kind/charts/pii-inspector-ui](https://github.com/tjorourke/solo/tree/main/agentic-pii-guardrail-kind/charts/pii-inspector-ui)

The chart references the image by tag (`pii-inspector-ui:dev` by default).
On a kind cluster you build + `kind load docker-image` once; for a real
cluster, push it to a registry your nodes can pull and set
`image.repository` / `image.tag`.

## Install

```bash
helm install inspector ./charts/pii-inspector-ui \
  --namespace my-ai-demo --create-namespace \
  --set agw.url=http://my-gateway.agentgateway-system.svc.cluster.local \
  --set agw.format=anthropic-messages \
  --set webhook.url=http://my-guardrail.guardrail-system.svc.cluster.local:8000
```

Then:

```bash
kubectl -n my-ai-demo port-forward svc/inspector-pii-inspector-ui 8090:80
open http://localhost:8090
```

## Values

| Key | Default | Required | Description |
|---|---|:-:|---|
| `agw.url` | `""` | ✅ | URL of your agentgateway Service (no trailing slash). The chart `fail`s if this is empty. |
| `agw.format` | `anthropic-messages` | | `anthropic-messages` or `openai-chat`. |
| `agw.path` | `""` | | Override the default path for the selected format. Use this when the gateway exposes the LLM route under a non-default prefix (e.g. `/openai/v1/chat/completions`). |
| `agw.model` | `""` | | Model passed in the request body. Empty → use the format default (`claude-haiku-4-5-20251001` or `gpt-4o-mini`). Many gateways accept `""` and let the `AgentgatewayBackend` pin the model. |
| `webhook.url` | `""` | | Optional. Set to enable the "what the LLM saw" trace column. Must point at a Guardrail Webhook implementation that exposes `GET /events` returning the audit ring JSON used by [`solo-demos/agentic-pii-guardrail-kind/src/guardrail-webhook`](../../src/guardrail-webhook/app.py). |
| `image.repository` | `pii-inspector-ui` | | |
| `image.tag` | `dev` | | |
| `image.pullPolicy` | `IfNotPresent` | | |
| `service.type` | `ClusterIP` | | |
| `service.port` | `80` | | |
| `replicaCount` | `1` | | Keep at `1` if you depend on the webhook's in-memory event ring (the inspector queries one webhook replica). |
| `resources` | `25m / 64Mi → 200m / 256Mi` | | |
| `extraEnv` | `[]` | | Free-form env passed through to the container. |

See [`values.yaml`](values.yaml) for the full schema.

## Recipes

### A. With Solo's reference Guardrail Webhook + Anthropic backend

The setup from this lab, packaged for reuse:

```bash
helm install inspector ./charts/pii-inspector-ui -n pii-demo \
  --set agw.url=http://pii-gateway.agentgateway-system.svc.cluster.local \
  --set agw.format=anthropic-messages \
  --set agw.model=claude-haiku-4-5-20251001 \
  --set webhook.url=http://pii-guardrail-webhook.pii-demo.svc.cluster.local:8000
```

### B. With an OpenAI-compatible backend (any provider) and your own webhook

```bash
helm install inspector ./charts/pii-inspector-ui -n my-ai \
  --set agw.url=http://my-agw.agentgateway-system.svc.cluster.local \
  --set agw.format=openai-chat \
  --set webhook.url=http://my-guardrail.my-ai.svc.cluster.local:8080
```

### C. Generic-gateway mode (no webhook implemented yet)

Useful for smoke-testing an LLM route or watching a built-in
`regex.action=Reject` fire as a 403:

```bash
helm install inspector ./charts/pii-inspector-ui -n my-ai \
  --set agw.url=http://my-agw.agentgateway-system.svc.cluster.local \
  --set agw.format=openai-chat
# webhook.url left empty → trace column hidden, raw HTTP body always shown
```

### D. The gateway exposes the route under a prefix

If the HTTPRoute matches `/openai/v1/chat/completions` instead of just
`/v1/chat/completions`, set `agw.path` explicitly:

```bash
helm install inspector ./charts/pii-inspector-ui -n my-ai \
  --set agw.url=http://my-agw.agentgateway-system.svc.cluster.local \
  --set agw.format=openai-chat \
  --set agw.path=/openai/v1/chat/completions
```

## Wiring it up to your gateway

For the inspector to talk to a gateway in another namespace, no
`ReferenceGrant` is needed — it's a normal pod making outbound HTTP. Just
make sure your Service DNS resolves from `my-ai-demo` (or whatever
namespace you install the inspector into).

If the gateway is north-south and exposed via a LoadBalancer IP, set
`agw.url=http://<external-ip>` — the inspector doesn't care whether the
hop is cluster-internal or external.

## What the webhook needs to expose for trace mode

Two endpoints — both are JSON, both are documented in
[`src/guardrail-webhook/app.py`](../../src/guardrail-webhook/app.py):

1. **The standard Solo Guardrail Webhook API** — `/request` and `/response`.
   These are what agentgateway calls. The inspector does not call these.
2. **`GET /events?limit=<n>`** — an *admin* endpoint, not part of the AGW
   contract. Returns the audit ring as a JSON array, newest first:

   ```json
   [
     {
       "id": "abc123",
       "ts": 1700000000.5,
       "phase": "request",
       "action": "mask",
       "original": [{"role": "user", "content": "My SSN is 123-..."}],
       "redacted": [{"role": "user", "content": "My SSN is [REDACTED]"}],
       "matches": ["SSN"],
       "reason": "masked: SSN"
     }
   ]
   ```

   If you BYO a webhook, expose the same shape on `/events` and the
   inspector will render it.

## Test plan

```bash
# 1. Healthy?
kubectl -n my-ai-demo port-forward svc/inspector-pii-inspector-ui 8090:80 &
curl -s localhost:8090/healthz   # → ok

# 2. Round-trip works?
open http://localhost:8090
# Type a benign prompt ("What's 2+2?") and confirm column 3 has text.

# 3. Trace mode?
# With webhook.url set, send a prompt with PII and confirm column 2 shows
# MASK with the matched pattern chips.

# 4. Pod logs surface the config?
kubectl -n my-ai-demo logs deploy/inspector-pii-inspector-ui --tail=1
# Expected:
# inspector-ui addr=:8080 agw=http://.../v1/messages format=anthropic-messages model=... webhook=http://...
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Column 3 empty + red badge "empty completion text" | LLM returned 200 but no text content blocks (e.g. tool-use only, or refusal) | Expand "raw HTTP body" under column 3 — the raw response from your gateway is always there. |
| Column 2 always says "no webhook configured" even though you set `webhook.url` | Inspector pod didn't pick up the value | `kubectl ... rollout restart deploy/inspector-pii-inspector-ui` and check the boot log. |
| Column 2 always says "pass" even when you sent obvious PII | Your gateway isn't applying the guardrail policy | Check the policy is `Accepted: True, Attached: True` against the route the inspector hits. |
| Send fails with `connection refused` | `agw.url` wrong, or Service in another namespace not resolvable | Verify with `kubectl run --rm -it tmp --image=curlimages/curl -- curl -v $AGW_URL/v1/messages`. |
