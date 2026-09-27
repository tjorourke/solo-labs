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
are real and billable. The gateway holds the provider credential; the agent
has only its lab JWT. Prompts contain specimen data. Agent answers are capped
at 256 tokens, and rate-check replies at 16 tokens.

## Prerequisites

- Existing `kind-mesh1`, Enterprise kagent 0.4.3, Enterprise agentgateway 2026.8.2
  and ambient Istio with trust domain `mesh1` and DNS capture.
- The installed `agentgateway-system/anthropic-secret` credential, whose
  `Authorization` key is copied into this lab's gateway namespace without printing it.
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

The agent is not given the `reset_demo_records` administration tool. The lab
operator uses it with the admin JWT after applying the tool policy, restoring
the same three open incidents for the after comparison. The App tab reads the
records through an authenticated, read-only gateway route. These are live
records in the MCP server, not hard-coded success counters in the console.

An **agent turn** is an A2A `message/send` request. The response shows the actual
tool calls, tool results and final answer, not a simulated transcript. The App
tab displays the agent's Ready condition and its last returned A2A task.

A **boundary check** makes a direct HTTP or MCP request from the kagent-managed
runtime to prove what that workload identity can reach. The notebook labels
these explicitly. They do not pretend that a curl request is an agent decision.
The egress and workload chapters use these checks and then show that the real
agent can still complete an allowed tool call.

| Layer | Before | After |
|---|---|---|
| Outside destination | Agent runtime reaches example.com | Waypoint refuses it; TCP RBAC counter increases; agent still investigates through the gateway |
| Workload identity | Direct MCP call bypasses the gateway | ztunnel refuses the defence-agent identity; its normal gateway tool call succeeds |
| Caller identity | Anonymous model request succeeds | Anonymous request gets 401; the authenticated agent turn succeeds |
| Tool permissions | Agent closes all three unresolved incidents | Alice sees only investigation tools; bulk close gets Unknown tool; all three restored records remain open |
| Personal data | Agent repeats specimen email | Agent turn fails; gateway records 403 and a Reject check; a clean turn succeeds |
| Rate | Bounded model requests succeed | Alice reaches 429; Bob remains allowed |
| Detection | Status and reason already recorded | New metric samples also identify the caller |

## Cluster-specific details

Kindnet accepts but does not enforce NetworkPolicy on this rig. A real HTTPS
fetch was tested before and after a temporary deny-all policy, and both returned
200. The egress chapter therefore uses an Istio waypoint and a namespace-private
ServiceEntry for example.com. It proves control of that destination, not a
blanket default-deny internet boundary. No shared CNI setting is changed.

The tool workload policy admits agentgateway and kagent's controller. The latter
needs direct access to discover the tools of the MCPServer it manages. It does
not admit the agent's own ServiceAccount. Its permitted path is through the
gateway and the tool policy.

The installed rate-limiter Service selects both the gateway and waypoint
instances, which have separate counters. A three-request limit allowed six
calls through that Service. The lab's `dd-rate-limiter` Service selects only the
active main ReplicaSet by its existing hash. No shared Deployment is changed.
Rerun setup if that platform Deployment rolls to a new ReplicaSet.

The rate check waits for ACCEPTED at the current generation. Each bounded loop
uses fresh Alice and Bob subjects so earlier checks do not consume its allowance.
A minute boundary can replenish the allowance during the loop. The check requires
successful calls, 429s and an unaffected Bob rather than an exact total across
that boundary. Agent turns may make multiple model requests; three requests is
not three turns. Caller labels are for this demonstration, not unbounded
production metric cardinality.

## Source, checks and reset

`build-notebook.py` builds the notebook and matching console spec. It embeds full
manifests in the Commands tab. `helpers.sh` handles MCP sessions, propagation
waits and bounded request loops; the console expands those functions. Agent
turns use plain curl and JSON-RPC in the notebook. `identity.py` creates local
test signing keys and one-hour tokens; restart from setup for a new run after
they expire.

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

`verify_console.py --only demo-13` passed **29/29 actions**, with reset before
and after (`console-20260927T154753Z`). All **34 console tests** and the image's
**4 incident-store tests** passed. Fixtures contain real A2A tool-call results.

The browser's App tab recorded the live transition from three open incidents
to three closed but unresolved incidents, followed by the administrator's
restore. After enforcement, the bulk-close request was refused and all three
records stayed open. The lab was left reset.
