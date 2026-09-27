"""Build the kagent defence notebook and matching console checks."""
import json
from pathlib import Path
import textwrap

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
cells, steps = [], {}


def cell(kind, source):
    c = {"cell_type": kind, "metadata": {}, "source": textwrap.dedent(source).strip().splitlines(True)}
    if kind == "code":
        c.update(execution_count=None, outputs=[])
    cells.append(c)


def chapter(n, short, title, say, point):
    cell("markdown", f"## {n}. {title}\n\n{say}\n\n{point}")
    cell("markdown", (HERE / "diagrams/architecture.svg").read_text())
    steps[str(n)] = {"short": short, "title": title, "say": say, "point": point, "blocks": []}


def action(title, instruction, expect, source, checks, **options):
    cell("markdown", f"### {title}\n\n{instruction}\n\n**Expected:** {expect}")
    cell("code", source)
    steps[next(reversed(steps))]["blocks"].append({
        "title": title, "instruction": instruction, "expect": expect,
        "checks": [{"label": label, "match": match} for label, match in checks], **options})


def apply(name, after=""):
    return "kubectl --context kind-mesh1 apply -f - <<'YAML'\n" + (HERE / name).read_text() + "YAML\n" + after


K = "kubectl --context kind-mesh1"
EXEC = K + " -n dd-agents exec deploy/defence-agent -- curl -sS --max-time 30"
BODY = "'{\"model\":\"claude-haiku-4-5\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply only READY\"}]}'"
CLOSE = "'{\"name\":\"close_all_incidents\",\"arguments\":{}}'"
READ = "'{\"name\":\"list_incidents\",\"arguments\":{}}'"
DIRECT = "http://defence-operations.dd-tools.svc:3000/mcp"
READ_PROMPT = "Use list_incidents to read the current incidents. Report the open count and affected services."
CLOSE_PROMPT = "Use close_all_incidents to close every open incident now. Report the actual changed count."
COMPLETE = ("Agent completed the turn", r'"state":\s*"completed"')
TOOL_READ = ("Agent read the incidents", r'"name":\s*"list_incidents"')
TOOL_CLOSE = ("Agent called bulk close", r'"name":\s*"close_all_incidents"')
OPEN = ("Three incidents open", r'"open_incidents":\s*3')


def model(token=False):
    auth = ' -H "Authorization: Bearer $ALICE"' if token else ""
    return f"{EXEC} -w '\\nHTTP %{{http_code}}\\n' \"$DD_URL/v1/chat/completions\"{auth} -H 'Content-Type: application/json' -d {BODY}"


def ask(prompt):
    # This is an actual A2A turn. Preserve the returned task for the live board.
    return '''DD_PUBLIC="http://$(kubectl --context kind-mesh1 -n dd-gateway get gateway dd-gateway -o jsonpath='{.status.addresses[0].value}')"
BODY=$(jq -nc --arg prompt PROMPT '{jsonrpc:"2.0",id:"lab",method:"message/send",params:{message:{role:"user",messageId:"defence-check",parts:[{kind:"text",text:$prompt}]}}}')
curl -fsS --max-time 120 "$DD_PUBLIC/a2a/" -H "Authorization: Bearer $ALICE" -H 'Content-Type: application/json' -d "$BODY" | tee "$DD_STATE/last-agent-task.json" | jq '{state:.result.status.state,calls:[.result.history[]?.parts[]?|select(.metadata.kagent_type=="function_call")|.data|{name,args}],results:[.result.history[]?.parts[]?|select(.metadata.kagent_type=="function_response")|.data|{tool:.name,output:(.response.structuredContent // (try (.response.content[0].text|fromjson) catch null) // .response.content),isError:(.response.isError // false)}],answer:[.result.artifacts[]?.parts[]?.text],error:.error}' '''.replace("PROMPT", "'" + prompt.replace("'", "'\\''") + "'")


METRICS = f'''POD=$({K} -n dd-gateway get pod -l gateway.networking.k8s.io/gateway-name=dd-gateway -o jsonpath='{{.items[0].metadata.name}}')
{K} get --raw "/api/v1/namespaces/dd-gateway/pods/$POD:15020/proxy/metrics" | grep -E '^agentgateway_(requests_total|guardrail_checks_total)' '''.strip()

cell("markdown", """# Layers of defence for an agent

A real kagent incident-response agent calls Claude through agentgateway and uses
operations tools deployed by kagent. It can investigate incidents, close them all,
or delete their investigation history. Tool calls really change a disposable dataset.
Each chapter adds a control and checks what changed.
Agent turns use A2A and show the returned tool-call trace. Direct HTTP and MCP requests
are labelled as boundary checks and run from the kagent agent's managed runtime.
There is no stand-in agent pod, echo model or hand-deployed tool server.

This lab uses Enterprise kagent, Enterprise agentgateway and Istio on mesh1.
Model calls use the installed Anthropic credential and are billable. Prompts use
specimen data, responses are capped and request loops are bounded.
Kindnet does not enforce NetworkPolicy, so the egress chapter controls example.com
through a namespace-scoped Istio waypoint. It does not claim a blanket internet boundary.
""")
cell("markdown", "## Connect\n\nSet the environment when following the notebook directly. The console sets it for every step.")
cell("code", f'''export DD=demo-scripts/defence DD_URL=http://dd-gateway.dd-gateway.svc
export DD_STATE="${{TMPDIR:-/tmp}}/defence-lab"
. "$DD/helpers.sh"''')

chapter(1, "Deploy with kagent", "Create an incident-response agent in kagent",
        "Build an incident-response agent in kagent and connect it to three open incidents. First, show that it can close every incident without fixing the faults. Then add policies that let it investigate but prevent those changes.",
        "kagent creates and manages the runtime. The model is Claude, reached through agentgateway. The provider credential stays at the gateway; the agent gets its own lab identity.")
action("Create the namespaces", "Enrol the lab's agent, tool and gateway namespaces in ambient.", "Three dd- namespaces are created.",
       apply("00-namespaces.yaml"), [("Namespaces", r"namespace/dd-(agents|tools|gateway) (created|unchanged)")])
action("Give the agent an identity", "Create the lab signing key and store Alice's gateway token in a Secret for kagent to reference. Copy the installed Anthropic credential into the lab gateway's namespace without printing it.",
       "The agent identity and gateway provider credential are stored separately.",
       f'''python3 "$DD/identity.py" setup
ALICE=$(python3 "$DD/identity.py" token --user alice)
{K} -n dd-agents create secret generic dd-agent-identity --from-literal="token=$ALICE" --from-literal="authorization=Bearer $ALICE" --dry-run=client -o yaml | {K} apply -f -
{K} -n agentgateway-system get secret anthropic-secret -o json | jq '{{apiVersion:"v1",kind:"Secret",metadata:{{name:"dd-anthropic",namespace:"dd-gateway"}},type:"Opaque",data:.data}}' | {K} apply -f -''',
       [("Agent identity", "secret/dd-agent-identity (created|configured|unchanged)"), ("Gateway credential", "secret/dd-anthropic (created|configured|unchanged)")])
action("Run the incident tool server", "Build the server for reading and changing the lab's incident records, then let kagent deploy it.",
       "The image's record-mutation tests pass and defence-operations reports Ready.",
       'docker build -t localhost:5001/defence-ops-mcp:v1 "$DD/operations-mcp"\ndocker push localhost:5001/defence-ops-mcp:v1\n' + apply("01-tools.yaml", f"{K} -n dd-tools wait mcpserver/defence-operations --for=condition=Ready --timeout=120s"),
       [("MCPServer ready", "mcpserver.kagent.dev/defence-operations condition met")])
action("Route model, tool and agent traffic", "Create the lab gateway. The model backend calls Anthropic, the MCP backend reaches the kagent-managed server, and the A2A route exposes the agent's runtime.",
       "dd-gateway rolls out. The agent route starts serving after the next step creates the Agent.",
       apply("02-gateway.yaml", f"{K} -n dd-gateway rollout status deploy/dd-gateway --timeout=120s"), [("Gateway ready", 'deployment "dd-gateway" successfully rolled out')])
action("Create the kagent Agent", "The ModelConfig uses agentgateway's OpenAI-compatible endpoint. The RemoteMCPServer registers the gateway's tools. The Agent references both.",
       "kagent accepts the Agent and its runtime becomes Ready.",
       apply("03-agent.yaml", f"{K} -n dd-agents wait agent/defence-agent --for=condition=Ready --timeout=180s"), [("Agent ready", "agent.kagent.dev/defence-agent condition met")])
action("Ask the agent to investigate", "Send an A2A message asking for the current incidents. Read the actual tool call and records returned by the agent, then check that kagent owns its Deployment.",
       "The agent reads three open incidents affecting payments, customer-api and settlement. Its Deployment is owned by Agent/defence-agent.",
       ask(READ_PROMPT) + f'''\n{K} -n dd-agents get deployment defence-agent -o json | jq '{{owner:.metadata.ownerReferences[0].kind,name:.metadata.ownerReferences[0].name,serviceAccount:.spec.template.spec.serviceAccountName}}' ''',
       [COMPLETE, TOOL_READ, OPEN, ("kagent owns the runtime", r'"owner":\s*"Agent"')], watch="app")
action("Declare the outside destination", "Put example.com behind an Istio waypoint visible only to dd-agents. This is a direct egress check from the kagent runtime, not an agent turn.",
       "The waypoint is Ready and HTTPS to example.com returns 200.",
       apply("04-egress-path.yaml", f'''{K} -n dd-agents rollout status deploy/dd-egress --timeout=120s
{EXEC} --retry 10 --retry-all-errors --retry-delay 1 -o /dev/null -w 'Outside HTTP %{{http_code}}\\n' https://example.com'''),
       [("Waypoint ready", 'deployment "dd-egress" successfully rolled out'), ("Outside reachable", "Outside HTTP 200")])
action("Select the installed rate limiter", "The default Service on this rig also selects the waypoint limiter, which has a separate counter. Create a lab-owned Service selecting the main limiter's active ReplicaSet.",
       "dd-rate-limiter selects the main limiter without changing its Deployment.",
       f'''HASH=$({K} -n agentgateway-system get rs -o json | jq -er '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Deployment" and .name == "rate-limiter-enterprise-agentgateway")) | select(.spec.replicas > 0)] | sort_by(.metadata.creationTimestamp) | last | .metadata.labels["pod-template-hash"]')
jq -n --arg hash "$HASH" '{{apiVersion:"v1",kind:"Service",metadata:{{name:"dd-rate-limiter",namespace:"agentgateway-system"}},spec:{{selector:{{app:"rate-limiter","pod-template-hash":$hash}},ports:[{{name:"grpc",port:8083,targetPort:8083}}]}}}}' | {K} apply -f -
{K} -n agentgateway-system get service dd-rate-limiter -o yaml''', [("Dedicated selector", "service/dd-rate-limiter (created|configured|unchanged)"), ("ReplicaSet selector", "pod-template-hash:")])

chapter(2, "Outside destination", "Control the agent's outside access",
        "Check whether the kagent runtime can reach example.com. Add a deny policy to its egress waypoint, then repeat the request.",
        "This checks a workload boundary directly. The request is not generated by the model. Kindnet does not enforce NetworkPolicy, so this chapter proves control of example.com only.")
action("Without the control", "Fetch example.com from the kagent agent's managed runtime.", "The HTTPS request returns 200.",
       f"{EXEC} -o /dev/null -w 'Outside HTTP %{{http_code}}\\n' https://example.com", [("Outside reachable", "Outside HTTP 200")], watch="app")
action("Add the control", "Deny traffic handled by this lab's egress waypoint.", "The AuthorizationPolicy is applied.",
       apply("05-egress-deny.yaml", "sleep 2"), [("Egress deny applied", "authorizationpolicy.security.istio.io/outside-deny (created|configured|unchanged)")], watch="app")
action("With the control", "Repeat the direct egress check and read the waypoint's RBAC counter. Then ask the agent to investigate incidents through its permitted model and tool paths.",
       "Outside access is refused and recorded. The agent still completes its tool call.",
       f'''if {EXEC} -o /dev/null https://example.com; then printf 'Unexpected outside access\\n'; exit 1; else printf 'Outside request refused\\n'; fi
{K} -n dd-agents exec deploy/dd-egress -- pilot-agent request GET 'stats?filter=rbac'
''' + ask(READ_PROMPT),
       [("Outside refused", "Outside request refused"), ("RBAC evidence", r"tcp\.rbac\.denied: [1-9]\d*"), COMPLETE, OPEN], watch="app")

chapter(3, "Workload identity", "Stop the agent bypassing the tool gateway",
        "The incident tools are managed by kagent. Without a workload policy, the agent runtime can also call them directly. Require agent traffic to pass through agentgateway.",
        "Istio checks SPIFFE identity. The gateway is admitted, and kagent's controller keeps direct access for tool discovery. The agent's own identity is refused on the direct path.")
action("Without the control", "Make a direct MCP call from the kagent runtime to the operations Service, bypassing agentgateway.", "The incident records are returned directly.",
       f'dd_mcp "$ALICE" tools/call {READ} {DIRECT}', [OPEN], watch="app")
action("Add the control", "Allow the gateway and kagent's discovery controller into the tool namespace. Do not admit the agent's ServiceAccount.", "gateway-only is applied in dd-tools.",
       apply("06-workload-identity.yaml", "sleep 2"), [("Workload policy", "authorizationpolicy.security.istio.io/gateway-only (created|configured|unchanged)")], watch="app")
action("With the control", "Repeat the direct MCP call and read the ztunnel refusal. Then ask the agent to investigate through its configured gateway path.",
       "Direct access is refused under the defence-agent SPIFFE identity. The agent's normal tool call still reads the incidents.",
       f'''if dd_mcp "$ALICE" tools/call {READ} {DIRECT}; then printf 'Unexpected direct tool access\\n'; exit 1; else printf 'Direct tool request refused\\n'; fi
{K} -n istio-system logs -l app=ztunnel --since=30s --tail=3000 | jq -c 'select(.["src.namespace"] == "dd-agents" and .direction == "inbound" and (.error // "" | contains("policy rejection"))) | {{source:.["src.identity"],destination:.["dst.namespace"],error}}'
''' + ask(READ_PROMPT),
       [("Direct call refused", "Direct tool request refused"), ("Agent identity recorded", "spiffe://mesh1/ns/dd-agents/sa/defence-agent"), ("Policy evidence", "allow policies exist, but none allowed"), COMPLETE, OPEN], watch="app")

chapter(4, "Caller identity", "Require a signed caller token",
        "The gateway currently accepts a model request without a token. Add Strict JWT authentication, then compare the anonymous request with the agent's authenticated turn.",
        "The agent's ModelConfig and RemoteMCPServer reference its identity Secret. The Anthropic provider key is held only by agentgateway.")
action("Without the control", "Make an anonymous model request from the kagent runtime. This is a protocol check, separate from the agent's normal configured calls.", "HTTP 200 without a token.",
       model(), [("Anonymous call accepted", "HTTP 200")], watch="app")
action("Add the control", "Read and apply the public JWT policy. Require the lab issuer and audience on the gateway.", "caller-identity is Accepted and Attached.",
       f'''cat "$DD_STATE/07-caller-identity.json"
{K} apply -f "$DD_STATE/07-caller-identity.json"
dd_wait_policy caller-identity''', [("Strict mode", '"mode": "Strict"'), ("Caller policy attached", "caller-identity Accepted and Attached")], watch="app")
action("With the control", "Repeat the anonymous request, then ask the kagent agent to investigate using its signed identity. Read the gateway's 401 log.", "The anonymous request gets 401. The agent's authenticated model and tool calls still complete.",
       model() + "\n" + ask(READ_PROMPT) + f"\n{K} -n dd-gateway logs deploy/dd-gateway --since=30s | grep 'http.status=401'",
       [("Anonymous refused", "HTTP 401"), COMPLETE, OPEN, ("Authentication evidence", "authentication failure: no bearer token found")], watch="app")

chapter(5, "Tool permissions", "Stop an agent closing unresolved incidents",
        "Ask the agent to close every incident. Without a tool policy, all three records change to closed even though their faults remain unresolved. Restore the sample records, restrict Alice to investigation tools, then repeat the request.",
        "A prompt is not the permission boundary. The gateway filters tools/list and refuses tools/call independently of the agent's behaviour.")
action("Without the control", "Ask the agent to close every open incident. Watch the App tab: the open count falls to zero, but the unresolved count stays at three.",
       "The real tool closes all three records. No underlying fault has been resolved.",
       ask(CLOSE_PROMPT), [COMPLETE, TOOL_CLOSE, ("Three records changed", r'"changed":\s*3'), ("All closed", r'"closed_incidents":\s*3'), ("Faults unresolved", r'"unresolved_incidents":\s*3')], watch="app")
action("Add the control", "Permit only list_incidents and get_incident for Alice. As the administrator, restore the disposable records so the after check starts from the same state.",
       "The policy is attached and the administrator restores three open incidents.",
       apply("08-tool-permissions.yaml", '''dd_wait_policy tool-permissions
dd_mcp "$ADMIN" tools/call '{"name":"reset_demo_records","arguments":{}}' '''),
       [("Tool policy attached", "tool-permissions Accepted and Attached"), ("Records restored", r'"reset":\s*true'), OPEN], watch="app")
action("With the control", "Repeat the same request to the agent. Check that write tools have disappeared, explicitly attempt bulk close, then ask the agent to read the records.",
       "Bulk close is unavailable to the agent and the gateway refuses an explicit call. Investigation still works, and all three incidents remain open.",
       ask(CLOSE_PROMPT) + f'''\nprintf 'Reader tools\\n'; dd_mcp "$ALICE" tools/list
printf 'Reader call\\n'; dd_mcp "$ALICE" tools/call {CLOSE}
''' + ask(READ_PROMPT) + f"\n{K} -n dd-gateway logs deploy/dd-gateway --since=30s | grep 'Unknown tool: close_all_incidents'",
       [("Bulk close refused", "Unknown tool: close_all_incidents"), TOOL_READ, OPEN, ("Caller recorded", "jwt.sub=alice")], watch="app")
steps["5"]["blocks"][-1]["checks"].append({"label": "Write tools hidden", "match": '"name":"(close_all_incidents|delete_incident_history|reset_demo_records)"', "absent": True, "from": "Reader tools", "to": "Reader call"})

chapter(6, "Personal data", "Refuse personal data before the model call",
        "Ask the agent to repeat a specimen email address. Add a request guard that rejects email addresses, then send the same message again.",
        "This uses a real model. The proof is a failed agent turn plus the gateway's 403 and Reject counter, not an echo simulator claiming what the model received.")
action("Without the control", "Ask the agent to repeat the specimen email.", "The agent completes and includes alice@example.test in its reply.",
       ask("Repeat this sample email exactly: alice@example.test"), [COMPLETE, ("Sample email returned", "alice@example.test")], watch="app")
action("Add the control", "Reject recognised email addresses on the model route before the provider call.", "reject-personal-data is Accepted and Attached.",
       apply("09-content.yaml", "dd_wait_policy reject-personal-data"), [("Guard attached", "reject-personal-data Accepted and Attached")], watch="app")
action("With the control", "Send the same message through the agent. Read the gateway's guardrail evidence, then send a message without personal data.",
       "The email turn fails with a gateway 403 and a Reject counter. The clean turn completes.",
       ask("Repeat this sample email exactly: alice@example.test") + f"\n{METRICS}\n" + ask("Reply only READY"),
       [("Agent turn refused", r'"state":\s*"failed"'), ("Gateway refusal", 'status="403"'), ("Guardrail evidence", r'agentgateway_guardrail_checks_total\{phase="Request",action="Reject"\} [1-9]'), COMPLETE], watch="app")

chapter(7, "Request rate", "Limit model requests per caller",
        "Send a bounded sequence of model requests from the kagent runtime. Add a global limit of three requests per minute per signed subject, then repeat the check.",
        "This is a protocol-level rate check. Agent turns can make multiple model requests, so a request allowance is not a turn allowance. Replies are capped at sixteen tokens and use the real provider.")
params = [{"name": "N", "label": "Requests", "default": 6, "min": 5, "max": 20}]
action("Without the control", "Send the bounded rate check with fresh Alice and Bob subjects.", "All requests return 200.",
       'dd_burst open "${N:-6}"', [("All accepted", r"Alice totals: accepted=\d+ limited=0"), ("Bob accepted", "Bob request: HTTP 200")], params=params, watch="app")
action("Add the control", "Apply the per-subject descriptor and wait for the limiter to load the current generation.", "The policy is attached and the limiter reports ACCEPTED.",
       apply("10-rate.yaml", "dd_wait_policy per-person-rate\ndd_wait_rate"), [("Rate policy attached", "per-person-rate Accepted and Attached"), ("Limiter loaded", "dd-per-person ACCEPTED at current generation")], watch="app")
action("With the control", "Repeat the bounded check and read the 429 metric. A request as Bob checks that the allowance is per identity.", "Alice reaches 429 while Bob still gets 200.",
       'dd_burst limited "${N:-6}"\n' + METRICS,
       [("Alice limited", r"Alice request \d+: HTTP 429"), ("Bob unaffected", "Bob request: HTTP 200"), ("Rate metric", r'agentgateway_requests_total\{[^\n]*status="429",reason="DirectResponse"[^\n]*\} [1-9]')], params=params, watch="app")

chapter(8, "Detection", "Read the recorded outcomes by caller",
        "The platform already records refusals. Add caller identity to the gateway metrics and generate another bounded rate check.",
        "The live board shows the kagent Agent and its last A2A task alongside policy state, gateway counters and workload refusal evidence. Detection observes; it does not add another refusal control.")
action("Before adding caller labels", "Read the gateway's own metrics.", "401, 403 and 429 outcomes are already recorded.",
       METRICS, [("401 recorded", 'status="401"'), ("403 recorded", 'status="403"'), ("429 recorded", 'status="429"')], watch="app")
action("Add caller labels", "Attach a metric attribute based on the validated JWT subject.", "identity-metrics is Accepted and Attached.",
       apply("11-detection.yaml", "dd_wait_policy identity-metrics"), [("Metrics policy attached", "identity-metrics Accepted and Attached")], watch="app")
action("With caller labels", "Generate new rate refusals and read the identity-labelled metrics.", "The 429 samples name the Alice subject. Bob remains allowed.",
       'dd_burst limited 6\n' + METRICS,
       [("Refusal enforced", "HTTP 429"), ("Bob works", "Bob request: HTTP 200"), ("Caller-labelled sample", 'caller="alice-')], watch="app")

cell("markdown", "## Reset\n\nRemove only this lab's kagent resources, gateways and credentials. The console checks that they are gone.")
cell("code", f'''{K} delete namespace dd-agents dd-tools dd-gateway dd-models --ignore-not-found --wait=true --timeout=180s
{K} -n agentgateway-system delete service dd-rate-limiter --ignore-not-found
rm -f "$DD_STATE/private.pem" "$DD_STATE/07-caller-identity.json" "$DD_STATE/last-agent-task.json"''')

notebook = {"cells": cells, "metadata": {"kernelspec": {"display_name": "Bash", "language": "bash", "name": "bash"}, "language_info": {"name": "bash"}}, "nbformat": 4, "nbformat_minor": 5}
spec = {"intro": "Runs a kagent incident-response agent with tools that read and change disposable incident records. Watch an over-permissioned agent close unresolved incidents, then restrict it to investigation. Claude calls go through agentgateway and are billable. Direct boundary checks are labelled separately. Egress covers example.com only. Follow the chapters in order and reset when finished.",
        "app": {"label": "Agent and defence layers, live", "url": "/defence/live", "hint": "kagent status, the last agent turn and policy evidence from mesh1."}, "steps": steps}
(ROOT / "demo-13-defence-in-depth.ipynb").write_text(json.dumps(notebook, ensure_ascii=True, indent=1) + "\n")
(ROOT / "demo-console/present/demo-13.json").write_text(json.dumps(spec, ensure_ascii=True, indent=2) + "\n")
print(f"Built {len(steps)} chapters, {sum(len(s['blocks']) for s in steps.values())} actions")
