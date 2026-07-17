# Ambient port audit: which ports are open, which are used, which should go

A compliance audit asks a blunt question about least privilege: is every port a
service is authorized to reach actually one it uses, and is anything else left
open? Services accumulate ports over time (a listener for a new feature, a debug
port from staging, a port some retired integration used), each one widens the
AuthorizationPolicy in front of the service, and the policy almost never gets
tightened back. The mesh encrypts all of it and the AuthorizationPolicy allows
most of it, but nobody can say which ports are actually earning their place.

This lab builds the audit that answers it, on Solo Istio in ambient mode, with
nothing beyond what ztunnel already emits:

- **svc-a → svc-b over ztunnel**, mTLS via HBONE, no sidecars.
- svc-b exposes **eleven ports**; svc-a uses **six** (8080-8082, 9090-9092);
  the AuthorizationPolicy allows **ten**, so four allowed ports never see a
  byte; port 7070 is exposed but not allowed, so a probe to it is denied by
  ztunnel and logged.
- **ztunnel access logs switched to JSON** (`LOG_FORMAT=json`) so they parse
  with jq instead of regex.
- A **collector DaemonSet** (Python, own Docker image, stdlib only): one pod
  per node STREAMS its LOCAL ztunnel's access logs over a single
  `follow=true` log connection (each ztunnel only sees its own node's pods)
  and merge-patches its OWN key in one central ConfigMap — on change,
  debounced, with a 60s heartbeat. The key value is **gzip+base64** (a whole
  ConfigMap has one 1 MiB budget across all its keys, and port/pod sets
  compress ~60x on a real fleet). Merge patches on distinct keys are
  conflict-free, so many nodes write the same ConfigMap concurrently with no
  resourceVersion/409 retry dance. A new port shows up in the node key about
  a second after the connection completes.
- An **aggregator CronJob**: unpacks + merges the node keys, reads the
  configured surface (Service ports + AuthorizationPolicy ports) and writes
  `report.json` (kept **plain** so humans, `jq` and the reporter agent can read
  it) with, per service: `configured_service_ports`, `authz_allowed_ports`,
  `used_ports`, `unused_ports`, `authz_allowed_never_used`, `denied_attempts`.

The end state is a machine-readable answer to three questions, per service and
per pod, over time: what is open, what is used, and what should be closed.

## Why Enterprise

The mesh is installed and lifecycle-managed by the Gloo Operator: one
`ServiceMeshController` CR renders istiod, istio-cni and ztunnel from the Solo
Istio images, with upgrades by editing `.spec.version`. The audit pattern
itself is plain Kubernetes + ztunnel behaviour.

## Watch the trust domain

The Gloo Operator sets the mesh `trustDomain` to the ServiceMeshController's
`.spec.cluster` (here `port-audit`), so identities are
`spiffe://port-audit/ns/...` and the policy principal is
`port-audit/ns/port-audit/sa/svc-a`. Write it as `cluster.local/...` and it
matches nothing, which turns the ALLOW policy into a deny-all for svc-b. The
ztunnel access log's `src.identity` field is the quickest way to see the real
trust domain.

## Prerequisites

- docker, kind, kubectl, helm, jq, make
- gcloud, authenticated (`gcloud auth login`) — the Solo Istio images are
  pulled from `us-docker.pkg.dev/soloio-img/istio` on the host and loaded
  into kind
- a Solo Istio license: export `SOLO_ISTIO_LICENSE_KEY`, or point
  `SECRETS_FILE` at a sourceable file that exports it

## Run it

The whole thing, standup to a 5-minute soak to asserted report, in one go:

```bash
make e2e SECRETS_FILE=~/path/to/secrets.sh
```

Or step by step:

```bash
export SECRETS_FILE=~/path/to/secrets.sh
make setup       # kind + Gloo Operator + ambient mesh + ztunnel JSON logs
make deploy      # collector image (docker build + kind load) + apps + policy + audit stack
make probe       # hit svc-b:7070 — exposed by the Service, denied by ztunnel
make report      # read report.json: used / unused / allowed-never-used / denied
make remediate   # apply the tightened policy the report justifies
make clean       # delete the kind cluster
```

The same steps as plain commands, if you want to see every move:

```bash
./scripts/setup-cluster.sh                 # kind + operator + ambient mesh + JSON logs
./scripts/build-collector.sh               # docker build collector.py + kind load

kubectl --context kind-port-audit apply -f yaml/10-app/
kubectl --context kind-port-audit apply -f yaml/20-policy/
kubectl --context kind-port-audit apply -f yaml/30-audit/

# a used port appears in its node key within ~2s; report.json rebuilds every 60s:
kubectl --context kind-port-audit -n port-audit-system get cm port-audit-report \
  -o jsonpath='{.data.report\.json}' | jq .
```

## The port story on svc-b

| Port | In the Service | In the policy | svc-a calls it | Report verdict |
| ---- | -------------- | ------------- | -------------- | -------------- |
| 8080 http-api | yes | yes | yes | used |
| 8081 inventory | yes | yes | yes | used |
| 8082 orders | yes | yes | yes | used |
| 9090 metrics | yes | yes | yes | used |
| 9091 health | yes | yes | yes | used |
| 9092 events | yes | yes | yes | used |
| 8083 admin | yes | yes | no | `authz_allowed_never_used` |
| 8084 debug | yes | yes | no | `authz_allowed_never_used` |
| 9093 profiling | yes | yes | no | `authz_allowed_never_used` |
| 9094 legacy-sync | yes | yes | no | `authz_allowed_never_used` |
| 7070 legacy | yes | no | probed once | `denied_attempts` |

`scripts/e2e.sh` runs the traffic for a five-minute soak (override with
`SOAK=seconds`) before it judges the report, so "used" means used during a
real observation window, not a single lucky request.

## Layout

```
kind/cluster.yaml            1 control-plane + 2 workers (per-node story needs 2)
collector/                   collector.py + aggregate.py + Dockerfile (one audit image)
scripts/setup-cluster.sh     kind + Gloo Operator + SMC(Ambient) + LOG_FORMAT=json
scripts/build-collector.sh   docker build + kind load for the collector image
scripts/e2e.sh               full run + 5-minute soak + report assertions
yaml/00-mesh/                ServiceMeshController
yaml/10-app/                 svc-a (client), svc-b (eleven listeners, spread across workers)
yaml/20-policy/              the L4 AuthorizationPolicy (over-provisioned on purpose)
yaml/30-audit/               report ConfigMap, RBAC, collector DaemonSet, aggregator CronJob
yaml/40-remediate/           the tightened policy the report justifies
yaml/50-agent/               (bonus) kagent reporter: ModelConfig, GitHub RemoteMCPServer, Agent
scripts/setup-kagent.sh      (bonus) install kagent + deploy the reporter agent
scripts/report-to-github.sh  (bonus) headless invoke; scripts/kagent-ui.sh opens the dashboard
```

## Bonus: kagent publishes the report to GitHub

Just for fun, and to show off what Solo's agentic stack can do, this lab
optionally deploys a **declarative AI agent on kagent**. The agent calls a `RemoteMCPServer`
wired to GitHub's MCP server, reads `report.json`, and turns that structured data
into clean, human-readable markdown committed straight to a GitHub repo, only
when the findings have actually changed. No report generator, no CI job, no git
plumbing, just a declarative agent with two tools.

```
report.json ConfigMap ──k8s_get_resources──► port-audit-reporter (kagent) ──create_or_update_file──► GitHub repo
                                              renders markdown, commits only on a diff
```

How it hangs together:

- **OSS kagent** on the same cluster (`scripts/setup-kagent.sh`): CRDs +
  controller + the built-in `kagent-tool-server` (the Kubernetes read tools) +
  the dashboard.
- **The GitHub MCP server is the auth answer.** We use GitHub's *hosted* MCP
  server at `https://api.githubcopilot.com/mcp/` (the local `github-mcp-server`
  binary only speaks stdio; kagent reaches MCP over HTTP). A **Personal Access
  Token** with `Contents: read+write` on the target repo is injected as the
  `Authorization: Bearer` header via `RemoteMCPServer.headersFrom`, sourced from
  the `github-mcp-pat` Secret. The token is created from `GITHUB_PAT` at setup
  time, never committed.
- **The `port-audit-reporter` agent** (`type: Declarative`) has two tool sets:
  `k8s_get_resources` (read the ConfigMap) and the GitHub MCP's
  `get_file_contents` + `create_or_update_file` (read the current file, write the
  new one). The whole behaviour is its system message: render `report.json` to
  markdown, `get_file_contents`, and commit only if the rendered markdown differs
  from what is already in the repo.

Run it:

```bash
export ANTHROPIC_API_KEY=...          # the model the agent runs on
export GITHUB_PAT=...                  # PAT, Contents:read+write on the repo
make kagent-setup                     # install kagent + deploy the reporter agent

# Prompt it in the dashboard:
make kagent-ui                        # http://localhost:8080, pick port-audit-reporter
#   "Publish the port audit to <owner>/<repo> at port-audit-report.md on main"

# or headless:
make kagent-report REPO=<owner>/<repo>
```

The agent reports whether it committed or skipped, with the commit URL. Run it a
second time with no traffic change and it says "No change" and commits nothing,
run `make probe` (or send new traffic) first and it commits the refreshed report.

## Teardown

```bash
kind delete cluster --name port-audit
```
