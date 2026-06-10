# agent-harness-openshell-kind

A kagent **AgentHarness** SRE on-call sandbox you attach to and ask to fix the cluster.

A single kind cluster. kagent OSS provisions an **OpenClaw** sandbox through an
**OpenShell** gateway (the `AgentHarness` primitive). You attach to that sandbox
and ask it, in plain English, to triage and remediate broken workloads. What it
is allowed to *change* is decided by Kubernetes RBAC, not by the model.

## The story

A `checkout` Deployment is broken on purpose (pinned to an image tag that does
not exist → `ImagePullBackOff`) in **two** namespaces:

| Namespace  | `autofix=true` label | What OpenClaw can do                          |
| ---------- | -------------------- | --------------------------------------------- |
| `incident` | **yes**              | **Fix it** — `kubectl set image`, pod recovers |
| `payments` | no                   | **Triage only** — patch returns 403 → Slack    |

OpenClaw can *read* every namespace (cluster-wide read), so it triages both. It
can only *write* where a namespace is labelled `autofix=true`, because the fix
permission is bound there and nowhere else. In `payments` the patch comes back
**403 Forbidden** from Kubernetes, so the agent escalates to **Slack** instead of
forcing the change. The guardrail is real RBAC — the agent cannot talk its way
past it.

## What gets installed

```
kind cluster (1 control-plane + 1 worker)
├── Gateway API CRDs
├── agent-sandbox controller        (sandboxes.agents.x-k8s.io)
├── OpenShell gateway               (the AgentHarness backend)
├── kagent OSS                      (controller wired to OpenShell)
│   ├── ModelConfig (Anthropic)
│   └── AgentHarness "sre-oncall"   (backend: openclaw)  → OpenClaw sandbox
├── RBAC: cluster read + label-gated fix
└── incident / payments namespaces  (each with a broken checkout Deployment)
```

## Bring it up

You provide your own model key (and, optionally, a Slack webhook). Nothing
secret is stored in this repo.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...   # optional
./scripts/quick.sh up
```

`SLACK_WEBHOOK_URL` is optional — without it, the agent reports escalations in
its reply instead of posting to Slack. You can also keep both in a file and
point `SECRETS_FILE` at it.

## Ask OpenClaw to triage and fix

```bash
# Triage only
./scripts/ask.sh "what is broken in the cluster?"

# Remediate: fix what's allowed, escalate the rest to Slack
./scripts/ask.sh "Triage every namespace for broken workloads. Fix what you are permitted to. If Kubernetes denies a change (403), do NOT force it - post a concise summary to the Slack webhook in /sandbox/.slack-webhook via curl. Summarize what you fixed and what you escalated."
```

Watch it work from another terminal:

```bash
kubectl --context kind-harness -n incident get pods -w
kubectl --context kind-harness -n payments get pods -w
```

Expected: `incident/checkout` is fixed (`nginx:1.27-alpine`, pod Running);
`payments/checkout` patch returns 403, so a Slack alert is sent and the pod is
left untouched.

The harness also shows up in the kagent dashboard next to your agents:

```bash
./scripts/port-forward.sh   # then open http://localhost:8080
```

## Reset / teardown

```bash
./scripts/06-broken-app.sh        # re-break both deployments to run it again
./scripts/quick.sh teardown       # delete the kind cluster
```

## Notes

- Needs `docker`, `kind`, `kubectl`, `helm`. Anonymous image pulls only (no
  registry auth). First bring-up pulls a few large images (OpenShell gateway +
  supervisor, kagent, the OpenClaw sandbox base) — give it a few minutes.
- The sandbox's kubeconfig uses a 24h token. Re-run `./scripts/05-equip-sandbox.sh`
  to refresh it (and the Slack webhook) without rebuilding the cluster.
- See `CLAUDE.md` for the design decisions and the end-to-end verification record.
