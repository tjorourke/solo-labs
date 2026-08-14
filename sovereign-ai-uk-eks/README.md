# Sovereign AI on EKS

An open-weight European model (Mistral-Small-3.2-24B on vLLM) self-hosted on UK
infrastructure (EKS, eu-west-2), with a zero-trust control at every layer around the
data path: Istio ambient identity, a Vault CA unsealed by KMS, Solo Enterprise
agentgateway as the one governed door, Kyverno and Pod Security Admission, kagent and
AgentRegistry for the agents, all in one region.

The write-up is a two-part lab:
- **Part 1 — the architecture:** https://mastertheagent.com/solo/sovereign-ai-uk-eks/
- **Part 2 — the exploits under test:** https://mastertheagent.com/solo/sovereign-ai-uk-eks/part-2/

This README is how to **run** it.

---

## Prerequisites

- An AWS account with an SSO profile (the lab runs in `eu-west-2`).
- The Solo licence keys in an env file, referenced by `SOVEREIGN_ENV_FILE`
  (`AGENTGATEWAY_LICENSE_KEY`, `SOLO_ISTIO_LICENSE_KEY`, `SOLO_LICENSE_KEY`).
- CLI tools on the machine you run from: `awscli`, `eksctl`, `kubectl`, `helm`, `docker`,
  `dig`, and `arctl` (the AgentRegistry CLI, at `~/.arctl/bin/arctl`) for the register phase.
- Account-level seed state the deploy assumes (created once, they survive a teardown):
  the three KMS keys `uk-sovereign-ai-{secrets,vault-unseal,cosign}` (created automatically
  if absent), and the in-region S3 weights bucket, hydrated once so the deploy restores the
  48 GB of weights from it rather than pulling from Hugging Face.

---

## Deploy

One command, from an empty-ish account to a working, defended model:

```bash
cd sovereign-ai-uk-eks
SOVEREIGN_AWS_PROFILE=<your-sso-profile> \
SOVEREIGN_ENV_FILE=<your-licences.env> \
./deploy-all.sh
```

It runs 16 phases in dependency order: cluster + node groups, the model (GPU + weight
restore + vLLM), the ambient mesh, Vault + istio-csr, Keycloak, the gateway + edge TLS, the
model-door policies, mesh enrolment, admission policy, observability, gVisor, kagent, the
management + registry consoles, the agent + MCP registration, the sovereignty seals, and a
final verify. Every phase is idempotent, so a re-run picks up rather than starting again.
Budget roughly an hour; the GPU meter (~$5.84/hr) starts at the `model` phase.

Run a single phase with `./deploy-all.sh <phase>`; list them with `./deploy-all.sh phases`.

At the end it prints the connectivity details below.

---

## Connect

`./scripts/access.sh` prints everything you need, resolved against the running cluster:

```bash
SOVEREIGN_AWS_PROFILE=<your-sso-profile> ./scripts/access.sh
```

**kubectl:**
```bash
aws eks update-kubeconfig --region eu-west-2 --name uk-sovereign-ai
# or a standalone file:
./scripts/access.sh kubeconfig      # writes ./uk-sovereign-ai.kubeconfig
```

**Consoles** — the UIs are behind the gateway on `*.sovereign.local`, which only resolves
through your hosts file. Add the line (run once; re-run `./scripts/access.sh hosts` if the
gateway is recreated and its IP changes):
```bash
echo "$(./scripts/access.sh hosts)" | sudo tee -a /etc/hosts
```
Then, in a browser, log in with a realm user (**password = the username**):

| Console | URL | |
|---|---|---|
| agentgateway | `https://age.sovereign.local/age` | traffic, traces, cost |
| kagent | `https://kagent.sovereign.local` | agents, sessions, per-run traces |
| agentregistry | `https://registry.sovereign.local` | catalogue, governance, traces |
| keycloak | `https://keycloak.sovereign.local` | the IdP (admin: `admin` / `admin`) |

Users: **carol / carol** (admin) · **alice / alice** (platform) · **bob / bob** (research).

---

## Ask the model

Directly over a port-forward (no token needed — this is the in-cluster path):
```bash
kubectl -n models port-forward svc/vllm 8000:8000
curl localhost:8000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"mistral-small-3.2-24b","messages":[{"role":"user","content":"what region are you in?"}]}'
```

Or through the gateway, with a real Keycloak token (the governed path a caller uses):
```bash
./scripts/ask.sh "what region are you in?"
```

---

## Demos (run on top, not part of standing up)

```bash
./scripts/observability.sh alert && ./scripts/observability.sh mail   # the SOC alert email, shown on screen
./scripts/artifactory.sh up && ./scripts/artifactory-ssrf.sh all      # the SSRF, then locked down layer by layer
./scripts/rate-limit.sh test                                          # 429 after 10 model calls a minute
./scripts/trivy.sh up                                                 # a CVE admission gate
./scripts/policy.sh test                                              # every admission policy refusing a real violation
```

---

## Teardown

```bash
./scripts/gpu.sh down            # just stop the GPU meter, keep the cluster
./scripts/teardown.sh down       # delete the cluster + the orphaned weights volume
```
Teardown deletes the LoadBalancer Services first so the gateway's ELB is cleaned up before
the VPC, checks the weights are safely mirrored in S3 before removing the local copy, and
leaves the KMS keys and the in-region weights bucket for the next deploy (about a pound a
month at rest).

---

## Scripts

`deploy-all.sh` orchestrates the phases; the pieces it calls, roughly in order:

| Script | What it does |
|---|---|
| `e2e.sh` | the model spine: VPC-CNI NetworkPolicy, storage, IRSA, GPU, weight restore, vLLM |
| `ambient.sh` | Istio ambient (base, istiod, cni, ztunnel); `enrol` labels the namespaces |
| `vault.sh` · `istio-csr.sh` | Vault (raft + KMS unseal) as the mesh CA, rewired via istio-csr |
| `keycloak.sh` | the Keycloak IdP + realm, and the CoreDNS rewrite for `keycloak.sovereign.local` |
| `agentgateway.sh` · `tls.sh` | the gateway control plane, the Gateway + routes, and the edge cert |
| `policy.sh` | Pod Security Admission + Kyverno |
| `observability.sh` | Prometheus, Grafana, Alertmanager, Mailpit |
| `substrate.sh` | gVisor on the sandbox node group |
| `kagent.sh` | the kagent runtime, OIDC to Keycloak |
| `management.sh` · `agentregistry.sh` | the management console + collector + ClickHouse, and AgentRegistry |
| `ar-agent.sh` · `ar-mcp.sh` | register + deploy the agent and the MCP server through AgentRegistry |
| `registry-mirror.sh` · `dns.sh` | the sovereignty seals: in-region image mirror, Route 53 DNS firewall |
| `access.sh` | print the connectivity details (kubeconfig, hosts, consoles, model) |
| `teardown.sh` | delete it all cleanly |
