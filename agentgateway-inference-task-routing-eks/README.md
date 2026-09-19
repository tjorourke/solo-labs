# Prompt-aware model routing, Part 4: private by default, frontier by exception

One endpoint for everyone in the company. The router says what kind of task a prompt is.
OPA turns the task and the caller's permissions into where it runs and which class of
model answers. Private GPUs are the default. The frontier is an exception: a clearly
generic coding question, from someone permitted to use it, and nothing else. Uncertain
stays private. Evidence that the prompt carries the company's own code keeps it private
whatever the task looked like. A credential in the prompt blocks it. A caller with no
permitted private model gets an error, never a frontier model.

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

### Why there are two gateways

A Gateway evaluates its policies in a fixed order and picks the route last: JWT, then
extAuth (OPA), then extProc (the router), then route selection. OPA is asked before the
router answers, so on one Gateway OPA is asked before the task exists. This flow needs the other order. So
the public gateway authenticates and classifies, and hands every request to a second,
internal gateway where OPA sees the task, the verified identity and the prompt together
and the route acts on OPA's answer. The router is called once. OPA returns both the pool
and the class.

```
client ──▶ model-gateway ────────────────▶ decision-gateway ──────────────▶ backend
           1 verify token (keep it)         3 verify token again            Qwen3-Coder    (private, coding)
           2 router: task label             4 OPA: task + permissions       Mistral        (private, finance / general)
             code_review | code_modification   + data checks → pool, class  Anthropic      (approved-frontier, generic coding)
             generic_coding | finance        5 route on pool and class
             uncertain
```

### The routing table

`opa/routing-data.json`, loaded into OPA as data. Permissions constrain the destinations
the table can select; the task determines the preferred one.

| Task (from the router) | Pool | Class | Model |
|---|---|---|---|
| `code_review` | private | coding | Qwen3-Coder-30B |
| `code_modification` | private | coding | Qwen3-Coder-30B |
| `finance` | private | finance | Mistral-Small-24B |
| `generic_coding` | approved-frontier, if permitted; otherwise private | coding | Claude Sonnet, or Qwen3-Coder |
| `uncertain` | private | general | Mistral-Small-24B |

| User | May use |
|---|---|
| bob | private, approved-frontier |
| alice | private |
| dave | approved-frontier only, so a review from dave is an error |

Rule precedence in `opa/routing.rego`, first match wins: a credential in the prompt blocks;
the company's own code in the prompt, or an internal repository named in `x-source-repo`,
forces private; then the table's preferred pool if permitted; then private if permitted;
then an error. There is no fall-through to the frontier.

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
./scripts/05-classify-gateway.sh  # 8  the public gateway verifies, classifies, hands on
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

```bash
source identity/tokens.env
./scripts/06-test-flow.sh         # 9   bob's five prompts and alice's one
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
yaml/30-decision-gateway.yaml     the second hop, ClusterIP
yaml/40-backends.yaml             Qwen3-Coder, Mistral, Anthropic, with the task labels aliased
yaml/50-decide-policy.yaml.tmpl   verify the token again, ask OPA with the body
yaml/60-decision-route.yaml       four rules on x-model-pool and x-model-class
yaml/70-classify-policy.yaml.tmpl verify and keep the token, run the router
yaml/80-classify-route.yaml       everything to the decision gateway
yaml/90-intake-gateway.yaml       the front door, ClusterIP
yaml/91-intake-policy.yaml        any model name becomes auto; unusable tool shapes dropped
yaml/92-intake-route.yaml         everything under /v1/ to the public gateway, Host rewritten; count_tokens answered by the gateway
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

Configure terminal Claude Code, or run the Desktop endpoint preflight:

```bash
HOST=$(tofu -chdir=tofu output -raw gateway_host) ./scripts/10-claude-code.sh
HOST=$(tofu -chdir=tofu output -raw gateway_host) ./scripts/11-claude-desktop.sh bob
```

### Claude Desktop

The [Claude Desktop section of the lab](https://mastertheagent.com/solo/agentgateway-inference-task-routing-eks/#claude-desktop)
contains the complete terminal-only setup, including the Python that generates the plist.
No Developer menu or token pasting is required. Desktop's inference settings are separate
from terminal Claude Code's `~/.claude/settings.json`.

1. Run `scripts/01-identity.sh` with this lab's existing signing key and save `BOB_TOKEN`
   to `~/.config/agw/token` with mode `600`. Do not create a new signing key for a gateway
   that still trusts a different JWKS.
2. Generate `$TMPDIR/com.anthropic.claudefordesktop.plist` using the lab's Python snippet.
   Use your gateway URL, `apiKey` credential kind and `bearer` auth scheme. This sends
   bob's JWT in `Authorization: Bearer`; it does not send a provider key to the desktop.
3. Install the generated profile:

   ```bash
   sudo mkdir -p "/Library/Managed Preferences"
   sudo install -m 644 -o root -g wheel "$TMPDIR/com.anthropic.claudefordesktop.plist" "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
   plutil -lint "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
   ```

4. Fully quit and reopen Desktop. Check the current startup log at
   `~/Library/Logs/Claude-3p/main.log` for your gateway's `inference apiHost` and a healthy
   gateway configuration. Writing a file into `Claude-3p/` alone did not activate the tested app.
5. In a new **Chat** conversation, ask `Explain what a Python list comprehension is`.
   Watch `decision-gateway` for bob, HTTP 200 and the actual serving model. If the separately
   started dashboard at `http://localhost:8900/` is in use, refresh it and reset filters
   before asking. It follows new requests after startup; the profile does not start it.

`scripts/11-claude-desktop.sh` tests the endpoint, but does not install Desktop's settings.
Remote URLs require HTTPS. A local port-forward at `http://127.0.0.1:<port>` also works.
The managed profile takes precedence over local `deploymentMode` changes. Its static JWT
must be renewed by regenerating and reinstalling the plist, then restarting Desktop.

Desktop's **Code** mode can attach repository instructions, files and tool results. Such a
request may stay private even when the typed question looks generic. Title-generation
requests are also separate from the user's prompt and can route differently.

The gateway prerequisites remain in `yaml/91-intake-policy.yaml`, `yaml/92-intake-route.yaml`
and `yaml/40-backends.yaml`: request normalisation, Messages and token-count mappings, and
provider configuration. The private backends' token overrides replace client values,
including smaller ones; they are not conditional caps. JWT policies authenticate the caller.

See the [agentgateway Claude Desktop documentation](https://agentgateway.dev/docs/standalone/latest/integrations/llm/clients/claude-desktop/)
for OIDC sign-in and managed fleet delivery.

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

### Teardown

```bash
./scripts/99-restore.sh           # Part 3's routing back; the models and the cluster are untouched
```
