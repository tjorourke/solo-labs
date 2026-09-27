# Layers of defence for an agent

Open `http://localhost:8900/demo-13` or follow
`../../demo-13-defence-in-depth.ipynb` from `vision-demo-2026`.
Run the chapters in order.

The **Diagram** tab shows the architecture and the before/after tool-policy
outcome in every chapter. `diagrams/design.py` defines the layout and generates
both the SVG and an editable `architecture.excalidraw` scene.
`diagrams/render.py` rebuilds those files and the PNG using the local gstack
offline renderer.

The incident-response agent is a **kagent Agent**, with a **ModelConfig** pointing
to agentgateway and a **RemoteMCPServer** registering its tool endpoint. Incident operations are deployed
with kagent's **MCPServer** resource. kagent creates and owns the runtime
Deployments and Services. The lab does not create a stand-in Pod, an echo model,
or ConfigMaps containing application code.

Claude Haiku 4.5 answers the agent's requests through agentgateway. Model calls
are real and billable. Prompts contain specimen data and agent answers are capped
at 256 tokens.

## Two gateways, two kinds of identity

People and the agent are identified in different ways, so they come in through
different gateways:

| Gateway | Class | Who uses it | How the caller is identified | Chapters |
|---|---|---|---|---|
| `dd-gateway` (front door) | `enterprise-agentgateway` | People: A2A turns, the read-only state view, the operator MCP route | Lab-signed JWT | 4 caller identity, 7 rate, 8 caller metrics |
| `dd-waypoint` | `enterprise-agentgateway-waypoint` | The agent: its model and tool calls | SPIFFE workload identity | 5 tool permissions, 6 personal data |

The agent holds **no user token and no provider key**. Its ModelConfig points at
the `model` Service behind `dd-waypoint`, which injects the Anthropic key; the
OpenAI client insists on a key string, so the agent's Secret holds a labelled
placeholder. Its RemoteMCPServer points at the `tools` Service with no headers.
The tool policy names the agent's workload (`source.identity`), not a claim in a
token the agent carries, so anyone who can talk to the agent does not inherit a
user's permissions through it. Both MCP backends use `entMcp` with
`failureMode: FailClosed`.

An earlier version gave the agent a one-hour "Alice" JWT in a Secret for its model
and tool calls. That let every caller act as Alice, and every agent turn failed
once the token expired.

## Prerequisites

- Existing `kind-mesh1`, Enterprise kagent 0.4.3, Enterprise agentgateway 2026.8.2
  and ambient Istio with trust domain `mesh1` and DNS capture.
- The installed `agentgateway-system/anthropic-secret` credential, which is copied
  into `dd-gateway` without printing it. No other namespace receives it.
- Docker and the suite's local registry on port 5001. Setup builds and pushes
  `localhost:5001/defence-ops-mcp:v1` from `operations-mcp/`. The image pins MCP SDK
  1.26.0 and runs its record-mutation and MCP result-schema tests during the build.
- The installed rate limiter, `kubectl`, `curl`, `jq`, Python 3 and `cryptography`.

This is an Enterprise lab: it uses Enterprise kagent and the gateway's
`RateLimitConfig` / `entRateLimit` integration. No additional cluster is created.

## Agent turns and boundary checks

The agent has `list_incidents`, `get_incident`, `close_all_incidents` and
`delete_incident_history`. The last two have real effects on disposable records:
bulk close changes incident statuses without resolving their faults; history
deletion removes the investigation entries. There is no production connection
or Kubernetes API client in the MCP server.

The agent is not given the `reset_demo_records` administration tool. Carol, the
lab operator, calls it through the front door's operator MCP route with an admin
JWT after the tool policy is applied, restoring the same three open incidents for
the after comparison. That route only admits the `admin` group. The App tab reads the
records through an authenticated, read-only gateway route. These are live
records in the MCP server, not hard-coded success counters in the console.

An **agent turn** is an A2A `message/send` request. The response shows the actual
tool calls, tool results and final answer, not a simulated transcript. The App
tab displays the agent's Ready condition and its last returned A2A task.

A **boundary check** makes a direct HTTP or MCP request from a kagent-managed
runtime to prove what that workload identity can reach. Agent-side MCP checks
carry no token, so the only thing identifying them is the agent's SPIFFE identity. The notebook labels
these explicitly. They do not pretend that a curl request is an agent decision.
The egress and workload chapters use these checks and then show that the real
agent can still complete an allowed tool call.

| Layer | Before | After |
|---|---|---|
| Outside destination | Agent runtime reaches example.com | Waypoint refuses it; TCP RBAC counter increases; agent still investigates through the gateway |
| Workload identity | Direct MCP call bypasses dd-waypoint | ztunnel refuses the defence-agent identity; its tool call through dd-waypoint succeeds |
| Caller identity | Anonymous agent request is served; another mesh workload can call the agent directly | Anonymous request gets 401; the direct call is refused at ztunnel; Alice's turn succeeds |
| Tool permissions | Agent closes all three unresolved incidents | The agent's identity sees only investigation tools; bulk close gets Unknown tool, logged with its SPIFFE identity; all three restored records remain open |
| Personal data | Agent repeats specimen email | Agent turn fails; dd-waypoint records 403 and a Reject check; a clean turn succeeds |
| Rate | Bounded agent requests succeed | Alice reaches 429 at the front door; Bob remains allowed |
| Detection | Status and reason already recorded | New metric samples also identify the caller |

## Cluster-specific details

Kindnet accepts but does not enforce NetworkPolicy on this rig. A real HTTPS
fetch was tested before and after a temporary deny-all policy, and both returned
200. The egress chapter therefore uses an Istio waypoint and a namespace-private
ServiceEntry for example.com. It proves control of that destination, not a
blanket default-deny internet boundary. No shared CNI setting is changed.

The tool workload policy selects the tool server's pods and admits `dd-waypoint`,
`dd-gateway` and kagent's controller. The controller connects directly to
discover the tools of the MCPServer it manages, so it is a privileged caller and
should be reviewed like one. The agent's own ServiceAccount is not admitted; its
path is through `dd-waypoint` and the tool policy.

The waypoint's MCP backends select the kmcp Service (`appProtocol:
kgateway.dev/mcp`) by namespace rather than naming a static host. Tested on
2026-09-27: with a `static` target the waypoint dialled the pod without a mesh
identity (ztunnel logged no `src.identity`), and the ALLOW-list above refused it.
With a Service selector it connects over HBONE as `dd-waypoint`.

Chapter 4 closes the agent to everything except the front door with an Istio
policy on the agent's pods. kagent's own answer for A2A is a waypoint
(`kagent.solo.io/waypoint: "true"`) with an `AccessPolicy`, and that is the right
tool for agent-to-agent calls through the agent's Service (see
agent-authoring-hosting-kind, Part 6). It does not cover this path: tested on
2026-09-27, the agentgateway front door sends to the agent's pod endpoints and
did not traverse the kagent waypoint, including with
`istio.io/ingress-use-waypoint`. An AccessPolicy there would never be consulted
for front-door traffic, so the lab does not deploy one.

Policy readiness is waited on, not slept on: `ZtunnelAccepted` for the
workload policies, `WaypointAccepted` for the egress deny and Accepted/Attached at
the current generation for agentgateway policies.

The installed rate-limiter Service selects both the gateway and waypoint
instances, which have separate counters. A three-request limit allowed six
calls through that Service. The lab's `dd-rate-limiter` Service selects only the
active main ReplicaSet by its existing hash. No shared Deployment is changed.
Rerun setup if that platform Deployment rolls to a new ReplicaSet.

The rate limit sits on the front door's agent route and counts agent requests
per validated JWT subject. The check waits for ACCEPTED at the current
generation. Each bounded loop sends short agent turns as fresh Alice and Bob
subjects so earlier checks do not consume its allowance. A refused request never
reaches the agent or the model. A minute boundary can replenish the allowance
during the loop, so the check requires successful calls, 429s and an unaffected
Bob rather than an exact total. Caller labels are for this demonstration, not
unbounded production metric cardinality.

The front door is plain HTTP on the local kind listener. Carry bearer tokens over
HTTPS anywhere else.

## Source, checks and reset

`build-notebook.py` builds the notebook and matching console spec. It embeds full
manifests in the Commands tab. `helpers.sh` handles MCP sessions, propagation
waits and bounded request loops; the console expands those functions. Agent
turns use plain curl and JSON-RPC in the notebook. `identity.py` creates a local
test signing key and one-hour tokens for people. The console mints fresh ones
for every step; in the notebook, rerun the Connect cell. Nothing in the cluster
holds a token, so nothing breaks when one expires.

Reset removes `dd-agents`, `dd-tools`, `dd-gateway`, the lab-owned rate-limiter
Service, local signing key and last task file. It also removes `dd-models` left
by the earlier simulator version. The console reads state back to confirm
removal. Other labs' namespaces and shared controllers remain untouched.

The canonical source is solo-demos. The notebook and this directory are mirrored
to solo-labs. Console fixtures and tests stay in the canonical repository.

## Verified run

2026-09-27 on `kind-mesh1`: Enterprise kagent **0.4.3** with the declarative
Python runtime **0.9.1**, Enterprise agentgateway **2026.8.2**, Solo Istio
**1.30.4-solo-distroless** and MCP SDK **1.26.0**.

`verify_console.py --only demo-13` passed **30/30 actions**, with reset before
and after (`console-20260927T180735Z`). The console tests passed, and the
image's incident-store tests passed during the build. Fixtures are captured from
that run and contain real A2A tool-call results and gateway evidence. The lab
was left reset.

This is an Enterprise-only lab (Enterprise kagent, `entMcp`, `entRateLimit`), so
there is no OSS run.
