# Demo console

One site on [http://localhost:8900](http://localhost:8900).

```bash
cp console.env.example console.env   # once: gateway hostnames and the EKS context
./run.sh
```

Setting up a laptop from scratch, and the EKS cluster behind the routing pages, is in
[../SETUP.md](../SETUP.md).

`/` is the catalogue: one card per demo. Each card opens that demo's own set of steps.
Filter it by area (**Connectivity** or **Agentic**, from each demo's `domain` in
`notebooks.DEMOS`) and switch between **Cards** and **List**. Both choices are remembered
in the browser.

## Agentics Overview

The hand-built pages, at `/user-story-1`.

| Path | Demo | What it is |
|---|---|---|
| `/user-story-1` | | Agentics Overview chapters |
| `/desktop` | 01 Enrol | Agentdesktop: fleet, enrol this Mac |
| `/decisions` | 02 and 03 Path and routing | Both Claudes on the gateway, then the question picks the model |
| `/economy` | 04 Economics | Token economics with MCP: Standard vs Code mode, on GitHub and on a calculator |
| `/cost` | 05 Cost | Cost management: live spend graph and Bob's budget in the EKS portal |
| `/agents` | 06 No-code | My agents: wizard, skills, MCP tools, approve |

## Guided labs

Each notebook section is a chapter. Each chapter shows one numbered action at a time,
with an instruction, an expected result and a Run button. **Commands** shows the exact
script for the selected action. **Run all steps** runs the remaining actions in the
current chapter, in order, stopping on a failed check or a command error.

| Path | Notebook | What it is |
|---|---|---|
| `/demo-1` | `demo-1-istio-ambient-multicluster.ipynb` | Ambient multicluster failover |
| `/demo-2` | `demo-2-istio-ztunnel-l4.ipynb` | Ambient L4 workload identity with ztunnel |
| `/demo-3` | `demo-3-istio-waypoint-l7.ipynb` | L7 policies with waypoints |
| `/demo-4` | `demo-4-agentics-vision.ipynb` | Build, ship and govern an ADK agent (§1-6 and §9) |
| `/demo-6` | `demo-6-inference.ipynb` | Inference routing on KV cache and queue depth (own `kind-inference` cluster) |
| `/demo-7` | `demo-7-llm-gateway.ipynb` | Model access with agentgateway |
| `/demo-12` | `demo-12-agent-substrate.ipynb` | Agent Substrate: WorkerPool, SandboxAgent, ActorTemplate, AgentHarness, snapshot and resume (`kind-mesh2`) |
| `/demo-11` | `demo-11-rest-to-mcp.ipynb` | Turn a REST API into MCP tools, then compose them |
| `/demo-13` | `demo-13-defence-in-depth.ipynb` | A kagent incident-response agent with operational tools, Claude through agentgateway, and before/after defence controls |
| `/demo-1/1.5` | | Failover chapter |

The original URLs remain valid. The names in the catalogue, navigation and lab pages
describe the subject rather than the notebook number.

`present/<demo>.json` contains the chapter copy and output checks. A block's optional
`parts` split its notebook cell at unique, exact `start` markers. All original commands
must be covered, and every part must pass `bash -n`. Each action gets a fresh shell with
the lab environment. Use `prepare` only to restore shell variables or functions needed
by a later part, never to repeat a cluster change. Actions use `set -eo pipefail`; a
test that deliberately triggers connection failures can opt out with `strict: false`
and must check the observed outcome.

The browser sends identifiers and a revision hash, not shell commands. A page opened
before an action was edited cannot run stale commands. Progress and per-action output
are stored for the browser session. A reset invalidates that progress. Only one action
or reset can run at a time in the console server.

### Inference routing live view

The inference routing lab's **App** tab is `/inference/live`: each replica's KV-cache use,
queue depth and running requests, read from its own `/metrics` (what the Endpoint Picker
scrapes), and how many requests the gateway sent to each, from its access log. The
cluster is `kind-inference`, brought up by `agentgateway-inference-routing-kind/scripts/quick.sh up`.

### Agent Substrate live view

The Agent Substrate lab's **App** tab is `/substrate/live`: the lab's `lab-pool` workers, the
ActorTemplates on it with their golden snapshots, every actor with its state and snapshot
version, and whether a gVisor sandbox process is alive for it, read from the worker node's
process table. Substrate Scope (the `/substrate` page) is fixed to the `kagent-default`
pool, so the lab does not use it.

The AgentHarness in the lab pins `acp-sandbox-openclaw` by digest: the Enterprise 0.5.6
controller was built without a default harness image and rejects a harness without one.

### Defence in depth live view

Every chapter of `/demo-13` has a **Diagram** tab showing what is being built:
the incident-response agent, agentgateway, Claude, the incident tools and the
Istio workload and egress checks.

`/demo-13` runs eight chapters on `kind-mesh1`. Its **App** tab, `/defence/live`,
polls `/api/defence/live` every 1.5 seconds. It reads the kagent Agent's status,
the last A2A task returned to the lab, actual incident records, policy status, the dedicated
gateway's metrics, its MCP refusal logs, inbound-only ztunnel refusal logs, and
the egress waypoint's TCP RBAC counter. Incident state is read through the
gateway's read-only `/ops-state` route with a lab JWT. Polling does not generate
agent turns, model calls or record mutations.
Applied policies and observed outcomes are shown separately. Read failures show
Unknown or Disconnected, rather than an apparently open control with zero refusals.
Counters are per current pod; log counts accumulate retained entries observed
since setup and are cleared on reset or a console restart.
The personal-data control rejects specimen email addresses before the model call.
The incident panel shows open, closed and unresolved counts. Bulk close really
changes the specimen records; it does not repair the underlying faults. The
administrator restores those records between the before/after tool-policy checks.

The lab uses three namespaces (`dd-agents`, `dd-tools`, `dd-gateway`)
and one Service (`agentgateway-system/dd-rate-limiter`). **Reset lab** deletes
those resources, checks their removal and deletes the local test signing key
and saved A2A result. It also removes `dd-models` from the earlier simulator
version. It does not change shared Deployments. Model calls use the installed
Anthropic credential and are billable. Only this lab is reset by:

```bash
python3 -m unittest test_console test_present test_defence
python3 -u verify_console.py --only demo-13
```

The runnable source and prerequisites are in `../demo-scripts/defence/README.md`.
To regenerate the notebook and spec after editing the builder or its manifests:

```bash
python3 ../demo-scripts/defence/build-notebook.py
```

### Terminal

Every lab page has a **Terminal** bar along the bottom. Click it, or press the backtick
key, to open a shell for that lab. **New shell** starts a fresh one; **↕** makes it taller.

- It has its own kubeconfig holding only that lab's clusters, with the lab's cluster as
  the current context, so plain `kubectl` goes to the right place and your global
  kubeconfig is never changed. The multicluster lab has both, `kind-mesh1` first.
- The lab's environment is loaded, the same as its steps get (`$LB`, `$GATEWAY`, `kc`,
  `mcp`, `arctl` logged in for Build an agent), and it starts where those steps run.
- Your `~/.bash_profile` loads first, so your aliases and functions work (`k`, `kgp`,
  `kgns`, `ns` ...). The lab environment and kubeconfig go on top of it. The profile's
  default AWS account is cleared: Build an agent sets its own profile, other labs have none.
- One shell per lab, kept while the console runs. Moving between chapters reconnects and
  replays the scrollback.
- It is a real shell on your laptop. The console only listens on 127.0.0.1, and the
  terminal endpoints refuse any request without the page's per-process token or from
  another origin. After a console restart an open page fetches the new token (same-origin
  only) and reconnects to a new shell by itself.

### Reset

**Reset lab** is on the final chapter and under **Environment and reset** on the lab
overview. `/admin` has individual reset controls and **Reset all labs**, reached through
the small **Admin** link below the top-right status badge. It is not an authentication
boundary. Lab badges check their own Kubernetes contexts; other pages show the
model-routing traffic feed connection.

- Multicluster: remove Bookinfo from both clusters and remove the lab's peering gateways.
- Ambient L4 identity: remove petshop and warehouse, then disable workload claims using
  the installed ztunnel chart version and values.
- Waypoint policies: remove petshop and its waypoint policies.
- Model access: remove only the named resources owned by this lab, restore both model
  simulators and clear gateway eviction state. Other stories' gateway resources stay up.
- Build an agent: scale the AgentRegistry platform up if it is parked, then run
  `demo-scripts/agentregistry/scripts/reset.sh`: the agent, its MCP servers, any
  AccessPolicy, the local scaffold and the AgentCore runtime instance. The approved
  catalogue stays.
- Agent Substrate: delete the lab's SandboxAgent, AgentHarness and WorkerPool, and read back that their ActorTemplates went with them.
- Inference routing: re-pin pool-a cold and pool-b hot, and read the gauges back.
- REST to MCP: remove the Petstore namespace, both MCP backends, the upstream backend,
  the two routes and the spec ConfigMap.

Every lab in `notebooks.DEMOS` gets its own control on `/admin`, and **Reset all labs**
covers them all. A new lab needs a `SCOPES` entry and a block in `reset_script()`.

The L4 and waypoint labs share petshop. Resetting either clears both labs' browser
progress. Reset reads cluster state back and reports failure if resources remain.

### Verification

From `demo-console/`:

```bash
python3 -m unittest test_console test_present
python3 verify_labs.py                         # every lab, reset before and after each
python3 verify_labs.py --only demo-1            # one lab
python3 verify_console.py                       # every lab through http://localhost:8900, as the browser runs it
```

`verify_console.py` drives the running console over HTTP: it reads each chapter page for
the action revisions and checks, runs them with `/api/notebook/run`, and resets with
`/api/labs/reset`. Use it after changing a lab, because it proves the page a presenter
clicks, not just the notebook.

The live runner executes the same actions and checks as the browser. Evidence is saved
under `data/lab-runs/<UTC timestamp>/`: output per action, check results, script revision
and reset results. Reference-only chapters have no live commands. The Model access lab
uses local Azure/Bedrock simulators and live Anthropic calls.

For investigation, `--no-reset-after` preserves a failed run. Resume with
`--no-reset-before --from-chapter <id> --from-action <number>`. Finish with a reset.

Spend, budgets and the 30-day graphs are the agentgateway Cost Management UI at
`https://$SOLO_UI_HOST/age/cost-management`, with `SOLO_UI_HOST` set in `console.env`.
The `/cost` card opens that page. Set Bob's budget on the Budgets tab.

```bash
cd vision-demo-2026/demo-console
./run.sh
# open http://localhost:8900
```

If 8900 is taken, the leftover is the old dashboard:

```bash
kill $(lsof -tiTCP:8900 -sTCP:LISTEN)
./run.sh
```

`run.sh` pins `KUBE_CONTEXT` to the current kubectl context. Override if you need to:

```bash
KUBE_CONTEXT=arn:aws:eks:eu-west-2:<account>:cluster/model-routing ./run.sh
```

## What you show on this page

Two tabs, each the same question asked twice.

**GitHub release report.** GitHub's hosted MCP server through agentgateway on mesh1.

1. Run the question in **Standard MCP**. Tokens and dollars tick up.
2. Toggle **Code mode**.
3. Run it again. Same answer, far less of the bill.

**Quadratic with a calculator** (`/economy#quadratic`). The calculator MCP server from
Part 4 §8 behind agentgateway on mesh1 (`quadratic_run.py` deploys it on first use),
and Claude through the Anthropic API. Standard serves six tools and the model calls one
per operation. Code serves `run_code` and the model writes one program. Tool calls,
tokens and time are measured on each run, so the numbers move a little run to run.

The 24 open pull requests are real, on [tjorourke/network-slice-manager](https://github.com/tjorourke/network-slice-manager). Reseed with `python3 seed_tickets.py`.

## Enrolling this Mac from the page

`/desktop` runs the enrol as three steps. Step 1 installs Agentdesktop as a system
service, which is the only way Claude Desktop can be managed: Desktop reads its policy
from `/Library/Managed Preferences`, and a daemon running as you cannot write there.
macOS raises its own authorisation dialog, so the whole flow stays on the page.

A user-mode enrol is still there under **Claude Code only, without a password**. It
cannot manage Claude Desktop, and it refuses a policy that carries Claude Desktop whole,
so pair it with the Claude Code-only policy.

The page never talks to the daemon's socket. Installing adds you to the `agentdesktop`
group, and a running process does not pick up a new group, so the console would
otherwise need restarting before it could show anything.
# Google Sovereign Cloud demo

The `/google` hub links routing, bank agents, the website workflow, the builder,
and MCP approvals. Berlin infrastructure and policy sources are in
`~/code/google-sov/poc/2026-09-agentic-platform`; see its `DEMO-READINESS.md`
and dated `deploy/inventory.json` for versions, load balancers and verification.

All Google agents use workload waypoints. MCP Services require a rotating
Kubernetes JWT matching the source mesh identity, plus a per-agent tool grant.
`google_builder.py` uses that repo's `mcp_policies.py` and `mcp_security.py` for
deployment/approval reconciliation. The fixed SDLC identities are `trustusbank-pm-agent`
and `trustusbank-dev-agent`, including their Keycloak clients.

TrustUsBank runtime `0.1.8` uses kagent-adk `0.10.0-rc5` and LiteLLM `1.103.2`.
Gemma tool responses are parsed as complete responses to avoid vLLM's older
streaming parser dropping quoted/fenced calls; A2A still emits tool events.

Run `./run.sh` after changing Python modules. The console prefers the isolated,
gitignored Berlin `deploy/console.kubeconfig`; it never selects the other demos'
inherited EKS/kind `KUBE_CONTEXT` for Google operations.
