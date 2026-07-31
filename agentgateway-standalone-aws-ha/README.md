# agentgateway standalone on AWS: three nodes, no Kubernetes

agentgateway as a plain binary under systemd on three EC2 instances, driven by **one
YAML file**. No CRDs, no controller, no Kubernetes. The state that makes three
independent processes behave like one gateway lives in managed AWS services.

Runs on the OSS build. Tested on `v1.4.1`.

---

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
```

---

## Before you start

You need:

- an AWS account and an **explicit** profile name. `scripts/lib.sh` refuses to run
  without `LAB_AWS_PROFILE`, and overrides anything a sourced secrets file
  exported, because sourcing one can silently repoint you at another account.
- a **public Route53 hosted zone**. HTTPS is not optional here: Cognito rejects
  non-localhost `http` redirect URIs, so the admin UI OIDC flow needs a real
  certificate, and ACM needs a zone to validate in.
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
export OPENAI_API_KEY=... ANTHROPIC_API_KEY=...

scripts/00-preflight.sh    # checks only, spends nothing
scripts/01-apply.sh        # build
scripts/02-verify.sh       # 3 healthy nodes, identical config hash on each
```

Then work through the demos. Each one explains itself as it runs.

| Script | What it shows |
| --- | --- |
| `10-routing.sh` | Path matching, rewrites, header manipulation, retries, CORS, fault injection. Ordinary API traffic through the same binary. |
| `11-auth.sh` | Cognito JWT validation and CEL authorization. Every refusal uses a real minted token, so 401 and 403 mean different things and you can see which. |
| `12-llm.sh` | Bedrock via the instance role, plus OpenAI and Anthropic. Virtual models, virtual keys, layered guardrails, per-request cost. |
| `13-mcp.sh` | A hosted MCP server and a REST API multiplexed into one tool list, with per-tool authorization that filters `tools/list` as well as gating `tools/call`. |
| `15-ratelimit.sh` | The difference between a per-process limit and a real one. |
| `20-ha-node-loss.sh` | Stop the gateway on a node, then destroy the instance and time the rebuild. |
| `21-ha-mcp-session.sh` | Drive one MCP session at all three nodes directly, then break it by changing one node's session key. |
| `22-ha-config-push.sh` | One `s3 cp` reconfigures the fleet, with a streaming response held open across the reload. |
| `23-ha-ui-overlay.sh` | A model added on one node appears on the others through Aurora, and survives destroying the node that created it. |

---

## What the HA testing showed

Every script was run against the live three node fleet. Four things were proven, and the
numbers are what the scripts printed rather than what the design predicted.

- **Self-healing in 139 seconds.** An instance was destroyed; a replacement built itself,
  loaded the same config and was serving, with nobody touching anything.
- **Sessions survive node loss.** One MCP session worked on all three nodes, so a client
  keeps working when the node it started on goes away. No sticky sessions and no session
  store.
- **Config changes with no downtime.** The whole fleet took a change with no restart, and a
  response streaming at the time delivered all 124 of its events uninterrupted.
- **Limits mean what they say.** A limit of 10 a minute allowed precisely 10 across three
  nodes; three independent per-node buckets would have let 30 through.

| Exercise | Result |
| --- | --- |
| Fleet health | 3 of 3 healthy, one per availability zone, identical binary version and config hash |
| Load distribution | 7 / 7 / 6 over 20 requests |
| Process loss | Out of service within ~20s, traffic continued on the survivors, back to 3 after restart |
| Instance loss | **139 seconds** from terminate to three healthy, replacement identical, no manual step |
| Portable MCP session, direct to each node | HTTP 200 on all three, each call ran on the node addressed |
| Portable MCP session, through the load balancer | 12 of 12 calls on one session, served by all three |
| Portable MCP session, negative test | Only the node with a different session key refused (400); restoring the key returned it to 200 |
| Config push | All three serving a new route within the sync interval, nothing restarted, **124 server-sent events** held across the reload |
| Overlay propagation | A model created on one node was published by all three in about 8 seconds |
| Overlay durability | The replacement for a destroyed node inherited it from Aurora |
| Per-node rate limit | 90 of 90 allowed against a 60 a minute per-process bucket |
| Fleet-wide rate limit | **Exactly 10 of 20 allowed**, a second caller unaffected |
| Rate limit degradation | With one node's limiter stopped, that node allowed and the others refused, as `failOpen` specifies |

Sixty-seven assertions across the nine scripts, all passing. Each capability test pairs a
positive case with a negative one: a token without the scope, a tool the caller is not
entitled to, a request past the limit.

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
| `config` | Startup-only. Addresses, the fleet-wide session key, Aurora, hybrid storage, the model cost catalog, tracing, logging. |
| `frontendPolicies` | The access log, including the node id so per-node attribution works in CloudWatch Logs Insights. |
| `gateways` | One named gateway on one port. Everything attaches to it. |
| `routes` | Node identity, a public API route, an authenticated one, a chaos route, A2A, and the MCP DCR route. |
| `llm` | Three providers, virtual models doing weighted split and failover, virtual keys, layered guardrails. |
| `mcp` | Two remote targets multiplexed, per-tool CEL authorization, OAuth resource metadata. |
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
