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

### Five things that cost me time

All five are documented in the config file's own comments, where they will actually
be read.

1. **Shell expansion does not respect YAML comments.** A dollar sign in a comment is
   expanded exactly like one in a value. A reference to a variable that is not set
   is a hard load failure, not an empty string.

2. **In hybrid mode the YAML is round-tripped before expansion.** The file goes
   through JSON and back out through the YAML emitter to merge the database overlay,
   and that happens *before* variables are expanded. A quoted variable reference
   survives it unquoted, because at that point its value is still the variable name,
   which needs no quoting. Expansion then produces a bare number and the next parse
   reads an integer where a string was required. This is why `guardrailVersion` is a
   literal in this config and not a variable.

3. **`config.tracing` and `frontendPolicies.tracing` are mutually exclusive.**
   Setting both is a startup error.

4. **`mcp.tool.name` is the name sent to the upstream target, not the prefixed name
   the client sees.** Multiplexing exposes `echo_whoami`; the authorization rule sees
   `whoami`. Select the server with `mcp.tool.target` instead of matching a prefix.

5. **Guard optional claims, and `has()` cannot guard all of them.** A machine token
   carries `scope` and no `cognito:groups`; a human token is the other way round. An
   unguarded reference to an absent claim makes the expression fail rather than
   return false, and a failed `allow` rule refuses. `has()` only accepts a field
   selection, so a claim name containing a colon needs
   `"cognito:groups" in jwt` instead.

### No identity provider to sign up for, and one thing that costs you

Cognito is created by the Terraform in this lab, so there is no third-party account
to open. It covers JWT validation, CEL authorization on claims, machine-to-machine
tokens through a resource server, and browser login for the admin UI.

What it does not cover is **OAuth Dynamic Client Registration**. An MCP client such as
Claude Code or Cursor can discover an authorization server from the gateway's metadata
and register itself; Cognito has no DCR, and neither does any other AWS service, so
there is nothing to point those clients at. A token you obtain yourself works fine.

agentgateway ships native MCP OAuth adapters for **auth0, keycloak, okta, descope,
authentik and entra**. Any one of them can be added as a second issuer on its own
route without touching the Cognito-backed routes. The exact shape is written out in
`config/config.yaml` immediately above the LLM section, and because routes reload live
it is one `aws s3 cp` to add.

Two other Cognito specifics worth knowing:

- Its **access tokens carry no `aud` claim**, only `client_id` and `scope`. That is
  why the `jwtAuth` policy configures issuer and JWKS and nothing else: audiences are
  optional, and requiring one here would reject every valid token.
- Its OAuth endpoints live on the **hosted-UI domain, not the issuer host**, so the
  UI's `oidc` policy names them explicitly instead of relying on discovery.

### One rule for a multi-node standalone fleet

**Do not use `stdio` MCP targets.** The encrypted session state includes the
upstream's address, and a `stdio` target is a child process of one specific node. A
sibling node can decrypt the session id perfectly and still have nothing to talk to.
Both targets in this lab are remote over streamable HTTP, which is what makes the
session genuinely portable.

---

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
