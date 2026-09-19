# Prompt-aware model routing, Part 4: private by default, frontier by exception

One endpoint for everyone in the company. The router says what kind of task a prompt is.
OPA turns the task and the caller's permissions into where it runs and which class of
model answers. Private GPUs are the default. The frontier is an exception: a clearly
generic coding question, from someone permitted to use it, and nothing else. Uncertain
stays private. Evidence that the prompt carries the company's own code keeps it private
whatever the task looked like. A credential in the prompt blocks it. A caller with no
permitted private model gets an error, never a frontier model.

Three models answer, and they cover four areas of expertise: private coding on
Qwen3-Coder, private finance and private telco on Mistral, and generic coding at the
approved frontier on Claude. Two of the four share a model, which is the point of routing
on a class rather than on a model name: what the request is about and which weights serve
it are two different decisions, and only the first one is the company's policy.

This part layers on [Part 3](../agentgateway-inference-identity-routing-eks/): same
cluster, same single GPU with both open-weight models, same router and OPA. It reorders
the decision. Part 3 decided where a request runs from the identity alone, before the
prompt was read. Here the task comes first.

**Editions.** `yaml/` is the Solo Enterprise CRDs, validated on Solo Enterprise for
agentgateway v2026.9.0, because the Enterprise UI is what reports on this flow: token usage
and spend per person, per task and per pool. `yaml-oss/` is the same set on the OSS CRDs, a
group and kind swap away, validated on upstream agentgateway v1.5.0. The routing needs
nothing Enterprise: `traffic.jwtAuthentication` with `preserveToken`, `traffic.extProc`,
`traffic.extAuth` with `forwardBody`, `traffic.transformation`, all at `phase: PreRouting`,
and `policies.ai.modelAliases` exist in both.

## Overview

### Why there are three gateways

A Gateway evaluates its policies in a fixed order and picks the route last: JWT, then
extAuth (OPA), then extProc (the router), then route selection. OPA is asked before the
router answers, so on one Gateway OPA is asked before the task exists, and a transformation
runs later still, after the router has already read the body. This flow needs both the other
way round, so it runs three Gateways with one job each: `intake-gateway` makes what the
client sent servable, `model-gateway` verifies the token and classifies the task, and
`decision-gateway` verifies again and lets OPA decide. The router is called once. OPA
returns both the pool and the class.

```
client ──▶ intake-gateway ──▶ model-gateway ──▶ decision-gateway ────▶ backend
           0 model name        1 verify token    3 verify token again  Qwen3-Coder  (private, coding)
             becomes auto,       (and keep it)   4 OPA: task +         Mistral      (private, finance / telco / general)
             tool shapes       2 router:            permissions +      Anthropic    (approved-frontier, generic coding)
             filtered            task label         data checks
                                                    -> pool, class
                                                 5 route on the two
```

Only `intake-gateway` is reachable from outside the cluster. The other two are ClusterIP,
and each verifies the bearer token itself rather than trusting the hop before it.

### The routing table

`opa/routing-data.json`, loaded into OPA as data. Permissions constrain the destinations
the table can select; the task determines the preferred one.

| Task (from the router) | Pool | Class | Model |
|---|---|---|---|
| `code_review` | private | coding | Qwen3-Coder-30B |
| `code_modification` | private | coding | Qwen3-Coder-30B |
| `finance` | private | finance | Mistral-Small-24B |
| `telco` | private | telco | Mistral-Small-24B |
| `generic_coding` | approved-frontier, if permitted; otherwise private | coding | Claude Sonnet, or Qwen3-Coder |
| `uncertain` | private | general | Mistral-Small-24B |

### Prompts

Three models, four areas of expertise. Every prompt goes to the same endpoint with the
same token, and names no model and no place. Each was run against the gateway on
19 September 2026 and landed where it says.

| Ask | Task | Where it lands |
|---|---|---|
| "What is our exposure to counterparty credit risk on uncleared derivatives?" | `finance` | Mistral on your own GPU |
| "How does a 5G network slice guarantee latency for an enterprise customer?" | `telco` | Mistral on your own GPU |
| "Review this function for concurrency bugs: `public void credit(long amt) { balance += amt; }`" | `code_review` | Qwen3-Coder on your own GPU, whoever asks |
| "What is the difference between a list and a tuple in Python?" | `generic_coding` | the approved frontier, only if permitted |

| User | May use |
|---|---|
| bob | private, approved-frontier |
| alice | private |
| dave | approved-frontier only, so a review from dave is an error |

Rule precedence in `opa/routing.rego`, first match wins: a credential in the prompt blocks;
the company's own code in the prompt, or an internal repository named in `x-source-repo`,
forces private; then the table's preferred pool if permitted; then private if permitted;
then an error. There is no fall-through to the frontier.

One adjustment runs after the pool is settled. Qwen3-Coder has no vision tower and vLLM
refuses a whole request carrying an image, so a pasted screenshot on a coding prompt came
back `400 qwen3-coder-30b is not a multimodal model`. A private request with an image now
moves to a class whose model can read it, with `image in prompt` in `x-routing-reason`. It
moves a request between private models only; the pool is never widened.

## Install

The prerequisite is a Kubernetes cluster, anywhere: 1.32 or later, a default StorageClass,
one node with an NVIDIA GPU of at least 96 GB labelled `role: gpu` (or change the
`nodeSelector` in the model manifests), two or three CPU nodes, and outbound access to
Hugging Face, ghcr.io, us-docker.pkg.dev and nvcr.io. This guide was run on EKS 1.34 and
nothing in it is specific to that. On your machine: `kubectl` pointed at the cluster,
`helm`, `openssl`, `python3`, `curl`, and `AGENTGATEWAY_LICENSE_KEY` in the environment for
the Enterprise charts. The OSS set in `yaml-oss/` needs no licence.

Where a component has a Helm chart it is installed from it with a values file; vLLM and OPA
are plain manifests (vLLM ships an image, not a chart; OPA's Envoy ext_authz plugin config
is not what the community chart is built around). Every step skips what exists.

```bash
./scripts/platform/10-agentgateway.sh   # 1  Gateway API v1.6.1, Enterprise agentgateway v2026.9.0, the UI, the Gateway
./scripts/platform/20-device-plugin.sh  # 2  NVIDIA device plugin 0.17.4, whole cards, one model per node
./scripts/platform/30-models.sh         # 3  Mistral-Small-24B and Qwen3-Coder-30B on vLLM, a card each (first run pulls 76 GB)
```

Or `./scripts/platform/up.sh`. Step 1 also installs the management chart, which is the
Enterprise UI, and the cost dimensions in `yaml/platform/11-dimensions-values.yaml`: the
task the router chose, and the pool and class OPA decided, alongside the built-in `model`,
`provider` and `user`. Installing and operating that UI is covered in the
[agentgateway quickstart](../agentgateway-quickstart-kind/) and
[LLM cost management](../agentgateway-cost-management-kind/) rather than repeated here.
Reach it with `kubectl -n agentgateway-system port-forward svc/solo-enterprise-ui 4000:80`.

On the OSS set, the one value that is not optional is
`controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES: "true"` in
`yaml-oss/platform/10-agentgateway-values.yaml`, alongside the Gateway API experimental
channel: ExtProc rides on both, and without them an ExtProc policy is Accepted and does
nothing.

## Configure

Needs an Anthropic key in the environment, for the one frontier route. About ten minutes:
the router restarts twice and the classifier weights are already on its volume.

```bash
export ANTHROPIC_API_KEY=...

./scripts/00-check.sh             # 4  the platform is serving
./scripts/01-identity.sh          #    tokens for bob, alice, dave, and a forgery; reuses Part 3's signing key
./scripts/02-router.sh            # 5  vLLM Semantic Router becomes a task classifier
./scripts/03-opa.sh               # 6  OPA with the routing table and the data checks
./scripts/04-decision-gateway.sh  # 7  the decision gateway, backends, policy and route
./scripts/05-classify-gateway.sh  # 8  the classify gateway verifies, classifies, hands on
```

Or `./scripts/quick.sh up`, which runs the install steps first and then these.

**Do not ship the ConfigMap.** It is the lab's entitlement source because it is the
smallest thing that proves the point. Kubernetes caps a ConfigMap at 1 MiB of data, every
change is a full rewrite and an OPA restart, and the data is readable by anything with
access to the namespace. A company-wide table belongs behind OPA's bundle API or in a data
source OPA queries at decision time; the gateway and the router do not change.

There is no Keycloak. The lab is about routing, and all the gateway needs from an identity
provider is a JWKS to check signatures against, so `01-identity.sh` generates an RSA key
per clone, writes its public half as `identity/jwks.json`, and mints RS256 tokens. A real
IdP replaces the inline JWKS with `jwks.remote`. Nothing else changes.

## Test

### Live decision dashboard

```bash
kubectl config get-contexts
KUBE_CONTEXT=your-lab-context python3 scripts/30-dashboard.py
```

Open <http://localhost:8900/>. This is the dashboard's canonical location; its scripts are
mirrored with the lab. It reads OPA decisions and decision-gateway access logs, matching
`traceparent` to the access log's trace **and span** IDs. It does not guess by user or time,
so concurrent requests cannot swap their backend model or HTTP status.

It loads the last 15 minutes on startup (`DASHBOARD_SINCE=5m` changes that window), follows
new requests, and binds only to loopback. `DASHBOARD_PORT` defaults to `8900`.
Requests with no backend result stay pending, not successful. Rows are grouped by caller
and displayed prompt, not a verified conversation ID. Housekeeping can be hidden with the
checkbox; system-reminder text is omitted from the displayed question, not from OPA's inspection.
Classification latency is omitted because this router build does not supply a correlatable
request ID in its decision log.

### Desktop compatibility

```bash
python3 scripts/12-test-desktop.py \
  --base-url https://agw.example.com \
  --token-file "$HOME/.config/agw/token"
python3 scripts/test_dashboard.py
```

Use bob's token for the live suite. It checks telco classification with Claude reminders,
content-part arrays and tool follow-ups, plus internal-code and credential controls. The
dashboard tests are isolated and exercise concurrent and out-of-order events.

The intake policy appends the latest human text without system-reminder blocks for VSR
classification; all original messages remain for OPA and the model. Mistral's final backend
transformation consolidates system text into one leading message while preserving non-system
messages and tool-call IDs. This avoids its `Unexpected role 'system' after role 'tool'`
HTTP 400. Later system instructions move to the beginning of the model context, so this is
a Mistral compatibility adapter, not a general requirement for every provider.

```bash
source identity/tokens.env
./scripts/06-test-flow.sh         # 9   bob's six prompts and alice's one
./scripts/08-show-decision.sh bob "Review this function for concurrency bugs: ..."   # 10  one request traced across both hops
./scripts/07-test-controls.sh     # 11  internal code, provenance, a credential, dave, spoofing, bad tokens
./scripts/classify.sh "Look at this code and tell me if the lock is released on every path."   # 12  tune the classifier
```

The flow reads three things off every response: `x-vsr-selected-model` is the router's task
label, `x-model-pool` and `x-model-class` are OPA's decision, and the `model` field in the
body is the serving model's own statement of which model answered.

## Reference

### What a client can and cannot name

The body's `model` field is not a request. The intake hop replaces whatever the client sent
with the router's own name, so a real model name in the body changes nothing: the task and
the caller's permissions still decide where it goes. The routing headers a client sends are
removed by OPA before it writes its own, and the task header is overwritten by the router.
`07-test-controls.sh` proves each of those, including an editor's envelope.

### Fail closed

Both policy components are `FailClosed`. With OPA down the gateway answers 403. With the
router down it answers 500. Neither case reaches a backend, and neither falls back to a
default.

### Files

```
yaml/platform/05-gateway.yaml              the public Gateway, ClusterIP
yaml/platform/11-dimensions-values.yaml    cost dimensions: user, task, pool, class
yaml/platform/20-device-plugin-values.yaml whole cards, affinity null
yaml/platform/30-vllm-mistral.yaml         Mistral on vLLM, a card to itself, 131072 window
yaml/platform/31-vllm-qwen.yaml            Qwen3-Coder on vLLM, a card to itself, 262144 window
opa/routing.rego                  the decision: block, force private, prefer, fall back, refuse
opa/routing-data.json             who may use which pool; task to pool and class; internal-code markers
yaml/10-router-tasks.yaml         the router as a task classifier: similarity banks, keywords, domains
yaml/20-opa.yaml                  OPA with /config, /policy and /data mounts
yaml/30-decision-gateway.yaml     the third gateway, ClusterIP
yaml/40-backends.yaml             Qwen3-Coder, Mistral, Anthropic, with the task labels aliased
yaml/50-decide-policy.yaml.tmpl   verify the token again, ask OPA with the body
yaml/60-decision-route.yaml       five rules on x-model-pool and x-model-class
yaml/70-classify-policy.yaml.tmpl verify and keep the token, run the router
yaml/80-classify-route.yaml       everything to the decision gateway
yaml/90-intake-gateway.yaml       the front door, ClusterIP
yaml/91-intake-policy.yaml        any model name becomes auto; unusable tool shapes dropped
yaml/92-intake-route.yaml         everything under /v1/ to the classify gateway, Host rewritten; count_tokens answered by the gateway
yaml-oss/                         the same set on the OSS CRDs, no licence needed
tofu/                             optional: the two public names, their certificates and their ELBs
```

### Publishing the endpoints (optional)

Everything above is ClusterIP and a port-forward, which serves `curl` and the scripts. A
real editor needs more than that: Cursor sends its chat completions from Cursor's own
backend rather than from the laptop, so the endpoint has to be reachable from the internet
with a certificate a browser already trusts.

`tofu/` is that, and nothing in the flow depends on it. It reads an existing Route53 hosted
zone and creates, per name, an ACM certificate validated by DNS, a LoadBalancer Service and
a CNAME pointing at the ELB that came back. The certificate ARN is why this is OpenTofu
rather than two more files in `yaml/`: it does not exist until ACM has issued it, so a
manifest would need somebody to paste it in, and then nothing in the repository describes
the running cluster.

```bash
ZONE=awslab.example.com ./scripts/platform/40-public-endpoints.sh            # plan, then apply
ZONE=awslab.example.com ./scripts/platform/40-public-endpoints.sh refresh-ip # new home address
ZONE=awslab.example.com ./scripts/platform/40-public-endpoints.sh adopt      # take over endpoints made by hand
ZONE=awslab.example.com ./scripts/platform/40-public-endpoints.sh destroy
```

Then point a client at it:

```bash
HOST=$(tofu -chdir=tofu output -raw gateway_host) ./scripts/10-claude-code.sh
HOST=$(tofu -chdir=tofu output -raw gateway_host) ./scripts/11-claude-desktop.sh bob
```

### Claude Desktop

Claude Desktop is not Claude Code and shares none of its configuration. It never reads
`~/.claude/settings.json`, so anything that points Claude Code at a gateway does nothing
here, and one machine can run Claude Code on the gateway and Desktop on Anthropic at the
same time. Desktop has its own setting, under developer mode: **Help > Troubleshooting >
Enable Developer Mode**, then **Developer > Configure Third Party Inference > Gateway**.

`./scripts/11-claude-desktop.sh [employee]` prints the values to type and then makes the
calls Desktop makes, so a broken endpoint fails there rather than in front of an audience.
Three things it checks that are easy to get wrong:

- **Bearer token, not API key.** Desktop sends an API key as `X-Api-Key` and a bearer token
  as `Authorization: Bearer`. The gateway's JWT policy reads the second, so the API key
  choice arrives with no credential.
- **HTTPS.** Desktop refuses a plain HTTP base URL anywhere but loopback, so a port-forward
  cannot serve it. That is what `tofu/` is for.
- **Restart.** The setting is read once, at launch. A running app keeps what it started
  with, which looks like the gateway ignoring you.

Two endpoints, published differently on purpose. The model endpoint is open, because every
request carries a JWT the gateway verifies and OPA decides what the subject may reach, so
the control is the token rather than the address; an allowlist would also refuse Cursor,
which arrives from Cursor's backend. The UI is not behind that policy and reaching it is
enough to read every prompt in the decision log, so it is published to the addresses in
`ui_allowed_cidrs` and the variable has no default.

A dynamic home address is the failure that variable causes most. The security group goes on
allowing an address your ISP has moved on from, the SYN is dropped rather than refused, and
the browser reports a timeout with nothing in any cluster log to explain it. `refresh-ip`
puts the current one back.

### Toggle both Claude clients

After the lab is running, install a launcher in Downloads:

```bash
./scripts/agw-toggle.sh --install
~/Downloads/agw-toggle.sh on
~/Downloads/agw-toggle.sh off
~/Downloads/agw-toggle.sh status
```

The Downloads launcher calls `scripts/agw-toggle.py` in this lab rather than maintaining a
second copy of its logic. `on` checks the gateway, reuses or renews the caller JWT with the
existing lab key, sets terminal Claude Code's endpoint and helper, and installs Desktop's
managed profile. It also replaces the static token in that profile when a new one is minted.

`off` removes this lab's managed inference settings, resets saved Desktop profiles to `1p`,
and clears the lab's terminal Claude Code endpoint and helper. It does not contact the gateway,
so it works when the cluster is unavailable. Both directions quit and reopen Claude Desktop;
resolve any save prompt so the normal quit can finish. Restart existing terminal Claude Code
sessions yourself. `--no-restart` writes the configuration without restarting Desktop.

macOS requests administrator authorisation when the managed plist needs changing. Cancelling
that request fails the toggle instead of reporting success. The script preserves unrelated
settings and stores private backups under `~/.config/agw/toggle/`. It refuses to overwrite a
different gateway's configuration or a per-user managed inference profile.

`status` reports configuration on disk, not the state of an already-running process. Confirm
Desktop's new startup in `~/Library/Logs/Claude/main.log` for native mode or
`~/Library/Logs/Claude-3p/main.log` for gateway mode. A stale `Gateway` label means the running
app still needs its configuration reloaded; changing only a local flag does not remove a
managed profile.

### Teardown

```bash
./scripts/99-restore.sh           # Part 3's routing back; the models and the cluster are untouched
```
