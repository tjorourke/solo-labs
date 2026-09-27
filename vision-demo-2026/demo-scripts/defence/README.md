# Layers of defence for an agent

Open `http://localhost:8900/demo-13` in the demo console, or follow
`../../demo-13-defence-in-depth.ipynb` from the `vision-demo-2026` directory.
Run the chapters in order. Each control chapter has a before request, the full
policy, and an after request with platform evidence. The setup has several
shorter steps. Detection and masking are labelled as observations and redaction,
not refusals.

## Prerequisites

- Existing `kind-mesh1`, ambient Istio with trust domain `mesh1` and DNS capture.
- Enterprise agentgateway 2026.8.2 and its installed rate limiter.
- Local images `localhost:5001/llm-gateway-mock:latest` and
  `localhost:5001/calc-mcp:latest`, already used by the other console labs.
  Their build sources are beside this directory. The calculator image uses the
  MCP Python SDK 1.x. This lab mounts its own model and tool implementations.
- `kubectl`, `curl`, `jq`, Python 3 and Python's `cryptography` package.

The model is a local OpenAI-compatible echo server. It records the prompt it
actually received so masking can be checked upstream. The MCP `delete_records`
tool is a dry run: there is no database, write or deletion. The agent pod has no
Kubernetes API token, privileges or capabilities. The demonstration requires no
model API credentials and creates no clusters.

This is an **Enterprise lab** because it uses `RateLimitConfig` and
`EnterpriseAgentgatewayPolicy.spec.traffic.entRateLimit`. It is not presented as
an OSS validation. Workload identity and the destination waypoint use Istio APIs.

## What the controls show

| Boundary | Before | After | Evidence |
|---|---|---|---|
| Outside destination | HTTPS to example.com returns 200 | Connection refused | `tcp.rbac.denied` on dd-egress |
| Workload identity | Agent calls model directly | Only gateway identity admitted | Inbound ztunnel log names source SPIFFE identity |
| Caller identity | No token returns 200 | No token 401, Alice token 200 | Gateway log and `reason="JwtAuth"` metric |
| Tool permissions | Alice lists and calls both tools | Deletion tool hidden; call gets Unknown tool | Gateway MCP log, Alice subject; admin dry run still succeeds |
| Personal data | Model receives sample email | Model receives `<EMAIL_ADDRESS>` | Model's `received_prompt` log and guardrail check counter |
| Rate | Bounded burst succeeds | Three requests allowed, then 429; Bob unaffected | Gateway `status="429",reason="DirectResponse"` |
| Detection | Status and reason already recorded | New samples also carry caller identity | Gateway's own metrics and the console App tab |

## Differences from the original proposal

**NetworkPolicy is not enforced by this rig's Kindnet.** A real HTTPS request
returned 200 before and after a temporary deny-all egress policy. A TCP connection
test is insufficient in ambient. The lab instead gives example.com a
namespace-private ServiceEntry and an Istio waypoint, then denies that waypoint's
traffic. This proves destination-scoped control only. It does not establish a
default-deny internet boundary. No shared CNI or namespace was changed.

**The installed rate-limiter Service selects two independent instances.** They
belong to the gateway and waypoint installations, with separate counters. A
three-request policy allowed six calls through that Service. Setup creates
`dd-rate-limiter` selecting the active main ReplicaSet by its existing hash.
This changes no shared Deployment or Service. Rerun setup if the platform's
rate-limiter Deployment has rolled to a new ReplicaSet since setup.

**The rate limiter needs time to load configuration.** The lab waits for
ACCEPTED at the current generation and fails on timeout. Bounded bursts use
fresh Alice and Bob subjects so reruns do not inherit a previous bucket. A
minute boundary can replenish the bucket during a burst; the test requires
successful calls, subsequent 429s and an unaffected Bob, not an exact count
across a wall-clock boundary. Caller labels are for this demonstration;
they are not a recommendation for unbounded production metric cardinality.

## Files and reset

`build-notebook.py` keeps the notebook and its console spec aligned. It embeds
the manifest contents directly into the policy cells. `helpers.sh` contains only
the MCP session exchange, bounded traffic loops and propagation waits; the console
shows those functions on the Commands tab. `identity.py` creates independent,
short-lived RS256 test identities and a public JWT policy. Private keys are kept
under `${TMPDIR:-/tmp}/defence-lab`, never in the repository.

Reset removes `dd-agents`, `dd-models`, `dd-tools`, `dd-gateway`, the
`agentgateway-system/dd-rate-limiter` Service and the local signing key. Other
labs' namespaces, gateways and policies are not modified. The console reset
reads resources back and fails if anything remains.

The canonical source is solo-demos. The notebook and this whole directory are
mirrored to solo-labs by the existing mirror workflow.

## Verified run

2026-09-27, `kind-mesh1`: Enterprise agentgateway **2026.8.2** and Solo Istio
**1.30.4-solo-distroless**. The console verifier passed **28/28 actions** with
reset before and reset after (`console-20260927T143307Z`). All **32 unit tests**
passed, including all fixture checks and the live evidence parser tests.

The App tab was checked in the browser during rate and detection chapters.
All control rows reached Enforced, Detection reached Observing, and the reset
view returned every row to Not deployed with zero counters. Desktop and mobile
layouts were render-checked. The recorded outputs are under
`demo-console/present/fixtures/demo-13/` in the canonical repository.
