# Solo Enterprise for agentgateway standalone on AWS: three nodes, no Kubernetes

Part 2 of the standalone fleet, and a setup guide. Part 1
(`agentgateway-standalone-aws-ha`) builds the same three-node shape on the OSS build;
this one builds it with **Solo Enterprise for agentgateway v2026.9.0** and turns on the
enterprise features.

Same premise: binaries under systemd on three EC2 instances, driven by **one YAML file**.
No CRDs, no controller, no Kubernetes. Two things are different to set up, and both are
covered below: there are **two processes per node**, and the proxy needs a **licence**.

```bash
# what the node bootstrap runs, and what you would run on a laptop
curl -fsSL https://run.solo.io/agentgateway/install | sh
export ENTERPRISE_AGENTGATEWAY_LICENSE_KEY=<your key>

~/.agentgateway/bin/agentgateway --version
~/.agentgateway/bin/agentgateway-sts --version
```

One installer, two binaries: `agentgateway` is the proxy and `agentgateway-sts` is the
security token service. Pin the release with `AGENTGATEWAY_VERSION` and choose where they
land with `AGENTGATEWAY_INSTALL_DIR`, which is what the launch template does so a node the
Auto Scaling group builds next week matches the two beside it.

## What this sets up

| Enterprise feature | How it is configured here | Script |
| --- | --- | --- |
| The STS | `entSts` in the shared config file, a second systemd unit per node, one signing key for the fleet from Secrets Manager. | `18-token-exchange.sh` |
| Impersonation | `backendAuth.oauthTokenExchange` on an MCP target, so the upstream is called with a token the gateway signs rather than the caller's. | `18-token-exchange.sh` |
| Dual authentication | `mcpAuthentication` on the listener for the client's credential, plus the exchange above for the backend's. | `18-token-exchange.sh` |
| Tool modes | `mcp.toolMode`, switched between `standard`, `search`, `code` and `codeSearch` with a config push. | `16-tool-modes.sh` |
| Composable MCP | `mcp.targets[].custom`: one tool defined as a pipeline of HTTP steps with CEL. | `17-composable.sh` |
| The read-write UI | `ui.policies.oidc` against Cognito, served on the fleet's own hostname, with edits shared through Aurora. | `23-ha-ui-overlay.sh` |

## What it demonstrates

| Problem on a fleet | How this solves it |
| --- | --- |
| Getting config to N nodes | An S3 object and a 30s sync timer. agentgateway watches its own config file, so one `aws s3 cp` reloads all three nodes with no restart and nothing dropped. |
| Config edited in the admin UI | `config.storage.mode: hybrid`. The file from S3 is the baseline; UI edits go to Aurora, and PostgreSQL `LISTEN/NOTIFY` tells the other nodes. A model added on one node is live on the other two, and a replacement node inherits it. |
| Analytics and cost split per node | One Aurora cluster as `config.database.url`, so the cost dashboard shows the whole fleet rather than a third of it. |
| MCP session affinity | None needed. Session state is AES-256-GCM encrypted *into* the `Mcp-Session-Id`, keyed by a fleet-wide secret, so any node can pick up a session any other node issued. Target group stickiness is off on purpose. |
| Rate limits that mean what they say | Envoy's rate limit service on each node against one ElastiCache cluster. 10 a minute is 10 for the fleet, not 10 per process. |
| Identity | Amazon Cognito, created by the Terraform here. It validates JWTs on the API, LLM and MCP routes, supplies the claims the CEL rules read, issues machine-to-machine tokens, and provides browser login for the admin UI. |

---

## Architecture

```
                        Route53 + ACM
                              |
                    internet-facing ALB :443
                    3 public subnets, 3 AZs
                    stickiness off, idle timeout 300s
                              |
        +---------------------+---------------------+
        |                     |                     |
   AZ a                  AZ b                  AZ c        Auto Scaling group
   EC2 t4g.medium        EC2                   EC2          min = max = 3
   agentgateway :3000    :3000                 :3000        arm64, systemd
   agentgateway-sts      127.0.0.1:7777        loopback     BindsTo the proxy
   echo upstream :8080   :8080                 :8080        no SSH, SSM only
   ratelimit :8081       :8081                 :8081
   metrics :15020        readiness :15021      admin 127.0.0.1:15000
        |                     |                     |
        +----------+----------+----------+----------+
                   |                     |
   Aurora PostgreSQL Serverless v2    ElastiCache Valkey
   writer + reader, 2 AZs             2 nodes, multi-AZ
   - request log, analytics, cost     - global rate limit counters
   - hybrid config overlay + NOTIFY

  S3 (versioned)        Secrets Manager          Cognito user pool
  config.yaml           session key              resource server + scopes
  model-costs.json      OIDC cookie secret       UI client, 2 machine clients
  echo-openapi.json     Aurora URL               platform / viewer groups
  ratelimit-config.yaml provider API keys
                        licence key
                        STS signing key
```

Two of those secrets are new in part 2 and both are deliberately fleet-wide:

- **the licence key**, read by both processes at every start.
- **the STS signing key**, so all three nodes sign with one key and a downstream
  service validates a token from any of them against one JWKS. Give each node its own
  key and a token minted on node A is rejected by a validator that fetched node B's.

---

## The operating system

The fleet runs **Ubuntu 24.04 LTS**. The enterprise binary is
`aarch64-unknown-linux-gnu` and needs **glibc 2.39**, which rules out Amazon Linux 2023
(2.34) and anything else older. Check a candidate host before you commit to it:

```bash
ldd --version | head -1     # needs to be 2.39 or newer
```

If your estate is on an older base, run the container image instead: it carries its own
userland, and the bundle image runs the proxy and the STS under one launcher.

---

## Before you start

You need:

- an AWS account and an **explicit** profile name. `scripts/lib.sh` refuses to run
  without `LAB_AWS_PROFILE`, and overrides anything a sourced secrets file
  exported, because sourcing one can silently repoint you at another account.
- a **public Route53 hosted zone that is actually delegated**. HTTPS is not
  optional here: Cognito rejects non-localhost `http` redirect URIs, so the admin
  UI OIDC flow needs a real certificate, and ACM needs a zone to validate in.

  "Delegated" is the part that bites. A hosted zone can exist in your account,
  hold records, and still be invisible to the internet because its parent has no
  `NS` record pointing at it. ACM validates over public DNS, so it will sit on
  `aws_acm_certificate_validation` until it times out, roughly 75 minutes, and the
  error says nothing about DNS. Check before you build:

  ```bash
  dig +short NS <your-zone> @8.8.8.8    # must return nameservers, not nothing
  ```

  If you do not have a delegated zone, the cheapest route is a subdomain of a
  domain you already own: create a Route53 hosted zone for, say,
  `awslab.example.com`, then add its four nameservers as `NS` records for `awslab`
  in whatever hosts `example.com`. On Cloudflare they must be **DNS only**, not
  proxied. That is self-service, costs $0.50/month for the zone, and is undone by
  deleting the four records.
- a **Solo Enterprise for agentgateway licence key**, exported as
  `AGENTGATEWAY_LICENSE_KEY`. The preflight fails without it, deliberately: the
  proxy checks the key at every start, so a fleet built without one builds fine and
  then never goes healthy, which is a fifteen-minute way to learn something the
  preflight can tell you in a second. The same key that licenses the Kubernetes
  product works here.
- OpenAI and Anthropic API keys. Bedrock needs neither: that provider
  authenticates with the EC2 instance role.
- `tofu` or `terraform`, `aws`, `jq`, `curl`.

### Cost

About **$0.45–0.55 an hour** with three NAT gateways. Set
`single_nat_gateway = true` and `redis_node_count = 1` to bring it to about
**$0.35**. Cold build is 12 to 18 minutes, mostly Aurora. Tear it down when you are
finished:

```bash
scripts/teardown.sh
```

---

## Run it

```bash
export LAB_AWS_PROFILE=<your aws profile>
export LAB_AWS_REGION=us-east-1
export LAB_ROUTE53_ZONE=<your public hosted zone>
export AGENTGATEWAY_LICENSE_KEY=<your Solo Enterprise licence key>
export OPENAI_API_KEY=... ANTHROPIC_API_KEY=...

scripts/00-preflight.sh    # checks only, spends nothing
scripts/01-apply.sh        # build
scripts/02-verify.sh       # 3 healthy nodes, identical config hash on each
```

Then work through the demos. Each one explains itself as it runs.

| Script | What it shows |
| --- | --- |
| `10-routing.sh` | Path matching, rewrites, header manipulation, retries, CORS, fault injection. Ordinary API traffic through the same binary. |
| `11-auth.sh` | Cognito JWT validation and CEL authorisation. Every refusal uses a real minted token, so 401 and 403 mean different things and you can see which. |
| `12-llm.sh` | Bedrock via the instance role, plus OpenAI and Anthropic. Virtual models, virtual keys, layered guardrails, per-request cost. |
| `13-mcp.sh` | A hosted MCP server and a REST API multiplexed into one tool list, with per-tool authorisation that filters `tools/list` as well as gating `tools/call`. |
| `15-ratelimit.sh` | The difference between a per-process limit and a real one. |
| `16-tool-modes.sh` | The same MCP listener in `standard`, `search`, `code` and `codeSearch`, counting the tool definitions a client is given each time. Enterprise only. |
| `17-composable.sh` | A tool defined as a pipeline of HTTP steps in the config file. One call, two requests, one answer. Enterprise only. |
| `18-token-exchange.sh` | Impersonation, delegation and dual authentication, each proved by decoding the credential the upstream actually received rather than describing it. Enterprise only. |
| `20-ha-node-loss.sh` | Stop the gateway on a node, then destroy the instance and time the rebuild. |
| `21-ha-mcp-session.sh` | Drive one MCP session at all three nodes directly, then break it by changing one node's session key. |
| `22-ha-config-push.sh` | One `s3 cp` reconfigures the fleet, with a streaming response held open across the reload. |
| `23-ha-ui-overlay.sh` | A model added on one node appears on the others through Aurora, and survives destroying the node that created it. |
| `24-ha-sts-loss.sh` | Stop the STS on one node and watch the node leave the load balancer's pool rather than half-serve. Enterprise only, because OSS has no second process to lose. |

---

## Proving it on three nodes

This is what the scripts printed on the live fleet, so you know what a good run looks
like. One node per availability zone, `us-east-1a`, `1b` and `1c`.

**The enterprise features, across the fleet**

- **Tool modes.** A new MCP session sees **7** tool definitions in `standard`, **2** in
  `search`, **1** in `code` and **2** in `codeSearch`, then 7 again on the way back. Each
  switch is one `aws s3 cp`, and all three nodes were on the new file within **5 to 15
  seconds**, with no restart.
- **Composable MCP.** One `tools/call` returns
  `node i-0ec6dff8a959c8ec7 in us-east-1b saw note 'hello'`: two HTTP steps and a CEL
  expression joining them, inside the gateway, in one round trip.
- **Impersonation.** The client presents a Cognito token; the upstream receives one issued
  by `https://agw-ent.awslab.masterthemesh.com/sts` with the same `sub`. Decoded from the
  headers the upstream actually saw, not from the config.
- **Dual authentication.** `POST /mcp` with no credential is `401` with a
  `www-authenticate` pointing at the resource metadata; with a valid one, the bearer that
  reaches the backend is a different token from the one the client sent.
- **The STS on every node.** All three report
  `{"service":"token-exchange-server","status":"healthy"}` on loopback.

**Failover**

- **Losing the proxy.** Stop `agentgateway` on one node: the ALB drops to two healthy
  targets, traffic continues on the other two, and a restart brings it back to three.
- **Losing the STS.** Stop `agentgateway-sts` on one node and the proxy stops with it
  within **5 seconds**, so the node leaves the pool rather than serving some callers and
  failing others. The ALB was down to two healthy targets **5 seconds** later. Of the 42
  requests in flight across the failure, **35 succeeded and 7 failed**, and an exchanged
  request was served by a surviving node throughout. Restarting both units returned the
  fleet to three healthy in **10 seconds**.
- **Losing the instance.** Terminate one outright: **194 seconds** from terminate to three
  healthy targets, with the Auto Scaling group building a replacement that installed the
  binaries, read the licence and the signing key from Secrets Manager, pulled the config
  from S3 and joined the fleet. It reported `version=v2026.9.0` and the same config hash
  as its siblings, with nobody touching it.

---

## The config file

`config/config.yaml` is the whole control plane, and it is worth reading before you
run anything. All three nodes hold it byte-identical: nothing is templated in.
agentgateway shell-expands the entire file before parsing, on first load and on
every reload, so every endpoint and credential is an environment variable reference
resolved from `/etc/agentgateway/env`, which each node renders from Secrets Manager
at boot.

Sections:

| Section | Contents |
| --- | --- |
| `config` | Startup-only. Addresses, the fleet-wide session key, Aurora, hybrid storage, the model cost catalogue, tracing, logging. |
| `frontendPolicies` | The access log, including the node id so per-node attribution works in CloudWatch Logs Insights. |
| `gateways` | One named gateway on one port. Everything attaches to it. |
| `routes` | Node identity, a public API route, an authenticated one, a chaos route, A2A, and the MCP DCR route. |
| `llm` | Three providers, virtual models doing weighted split and failover, virtual keys, layered guardrails. |
| `mcp` | Two remote targets multiplexed, per-tool CEL authorisation, OAuth resource metadata. |
| `ui` | The admin UI published through the data-plane gateway behind Cognito OIDC. |

### Six conventions for writing this file

1. **Define every variable you reference.** The file is shell-expanded on load and on
   every reload, so `$NAME` resolves from `/etc/agentgateway/env` wherever it appears.
   If one is missing the new config is not adopted and the node carries on serving its
   last good one, naming the variable in the log, so a push is safe to iterate on.

2. **Write placeholders in commented examples as prose.** Expansion covers comments as
   well as values, which is what lets this file carry a worked example of a second MCP
   issuer inline without needing an environment to match it.

3. **Write numeric-looking string values as literals** rather than variables.
   `guardrailVersion: "1"` is in the file for this reason, so a version stays
   unambiguous once the database overlay is merged in.

4. **Choose one place for span attributes**, either `config.tracing` or
   `frontendPolicies.tracing`, so what you read is what is exported.

5. **Select MCP servers with `mcp.tool.target`** and match tool names with
   `mcp.tool.name`, which is the name the target publishes rather than the multiplexed
   name the client sees. Rules then survive a rename or a `prefixMode` change.

6. **Guard optional claims, and give each identity type its own rule or descriptor.**
   Use `"cognito:groups" in jwt` for a claim name containing a colon, and list one rate
   limit descriptor per identity type. A machine token carries `scope`, a human token
   carries groups, and separate expressions stay readable.

Every policy here has a negative test alongside the positive one: a token without the
scope, a tool the caller is not entitled to, a request past the limit. That is what
makes the scripts worth re-running after a config change.

### One rule for a multi-node standalone fleet

**Do not use `stdio` MCP targets.** The encrypted session state includes the
upstream's address, and a `stdio` target is a child process of one specific node. A
sibling node can decrypt the session id perfectly and still have nothing to talk to.
Both targets in this lab are remote over streamable HTTP, which is what makes the
session genuinely portable.

---

## Rotating credentials

Every credential lives in one Secrets Manager document, and each node renders it into
`/etc/agentgateway/env` at start. Updating the secret does not reach a running node on its
own, so the general shape is: change it at source, put the new value in the secret, then
roll the fleet one node at a time.

```bash
scripts/30-rotate-credentials.sh --show   # which keys exist, and which need a restart
scripts/30-rotate-credentials.sh          # rolling re-render and restart, health-checked
```

| Credential | Needs a fleet roll | Visible to clients |
| --- | --- | --- |
| Aurora password | Yes | No, if the cluster change and the secret update are close together |
| Session key | Yes | Yes, MCP clients re-initialise |
| OIDC cookie secret | Yes | Yes, admin UI users sign in again |
| Provider API keys | Yes | No |
| Cognito client secret | Yes | No, a client can hold two secrets at once |
| Virtual keys | **No** | No, both keys work at once |

Virtual keys are the exception worth knowing: they are configuration rather than startup
credentials, so adding the replacement and deleting the old one needs no restart and no
roll. The page has the per-credential commands.

## Operating it

```bash
# change the fleet's config
aws s3 cp config/config.yaml s3://$(cd terraform && tofu output -raw config_bucket)/config.yaml

# shell on a node (there is no SSH, and no port 22 in any security group)
aws ssm start-session --target <instance-id>

# the admin API and UI, which stay on loopback
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=15000,localPortNumber=15000'

# what the running process actually loaded
curl -s localhost:15000/config_dump | jq .
```

Logs are in CloudWatch under `/agentgateway/agw-ha`, as JSON with a `node` field:

```
fields @timestamp, node, zone, user, llm_model, llm_cost_usd, mcp_tool
| stats count(*), sum(llm_cost_usd) by node
```

Metrics land in the `agentgateway/agw-ha` CloudWatch namespace, traces in X-Ray,
and the in-product analytics and cost dashboard are at `/ui`, backed by Aurora.
