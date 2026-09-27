"""Build the defence notebook and its matching console checks.

Run from any directory. Manifests are embedded in apply cells so the complete
policy is visible in Commands and the notebook remains the executable walkthrough.
"""
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
EXEC = K + " -n dd-agents exec unmanaged-agent -- curl -sS --max-time 8"
BODY = "'{\"model\":\"dd-echo\",\"messages\":[{\"role\":\"user\",\"content\":\"ordinary model request\"}]}'"
PROMPT = "'{\"model\":\"dd-echo\",\"messages\":[{\"role\":\"user\",\"content\":\"Contact alice@example.test for the sample.\"}]}'"


def model(token=False, body=BODY, url='"$DD_URL/v1/chat/completions"'):
    auth = ' -H "Authorization: Bearer $ALICE"' if token else ""
    return f"{EXEC} -w '\\nHTTP %{{http_code}}\\n' {url}{auth} \\\n  -H 'Content-Type: application/json' -d {body}"


METRICS = f'''POD=$({K} -n dd-gateway get pod -l gateway.networking.k8s.io/gateway-name=dd-gateway -o jsonpath='{{.items[0].metadata.name}}')
{K} get --raw "/api/v1/namespaces/dd-gateway/pods/$POD:15020/proxy/metrics" | grep -E '^agentgateway_(requests_total|guardrail_checks_total)' '''.strip()

cell("markdown", """# Layers of defence for an agent

An ordinary, unprivileged pod stands in for an unmanaged agent. It makes normal HTTP and MCP requests.
For each boundary, try the request, add a policy, then repeat it and read the evidence.
The model is a local echo simulator. The tool named delete_records only returns a dry-run message.
No real personal data or model credentials are used.

This lab uses Enterprise agentgateway 2026.8.2 for its global per-identity rate limit.
Istio's trust domain is mesh1. Kindnet does not enforce NetworkPolicy on this cluster,
so the egress chapter controls example.com through a namespace-scoped waypoint. It does not claim
to close every internet path. The content chapter masks rather than refuses; detection observes rather than blocks.
""")
cell("markdown", "## Connect\n\nSet the environment when following the notebook directly. The console sets it for every step.")
cell("code", '''export DD=demo-scripts/defence DD_URL=http://dd-gateway.dd-gateway.svc
export DD_STATE="${TMPDIR:-/tmp}/defence-lab"
. "$DD/helpers.sh"
''')

chapter(1, "Setup", "Create the lab's workloads",
        "Create four namespaces on mesh1, an unprivileged stand-in agent, a local echo model, two harmless MCP tools and a dedicated gateway.",
        "All demonstration traffic comes from unmanaged-agent. Reset removes these workloads. The installed platform is shared.")
action("Create the namespaces", "Enrol this lab's namespaces in ambient.", "Four dd- namespaces are created.",
       apply("00-namespaces.yaml"), [("Namespaces", r"namespace/dd-(agents|models|tools|gateway) (created|unchanged)")])
action("Load the sample model and tools", "Store the model and tool server's Python files in Kubernetes ConfigMaps. The next step mounts these files into pods and runs them.", "Both ConfigMaps are created with the Python files the pods will run.",
       f'''{K} -n dd-models create configmap model-code --from-file="$DD/model.py" --dry-run=client -o yaml | {K} apply -f -
{K} -n dd-tools create configmap tools-code --from-file="$DD/tools.py" --dry-run=client -o yaml | {K} apply -f -''',
       [("Model code", r"configmap/model-code (created|configured|unchanged)"), ("Tool code", r"configmap/tools-code (created|configured|unchanged)")])
action("Start the agent, model and tools", "Start the agent pod, model simulator and tool server using container images already on mesh1.", "The agent is Ready and both Deployments roll out.",
       apply("01-workloads.yaml", f'''{K} -n dd-agents wait pod/unmanaged-agent --for=condition=Ready --timeout=120s
{K} -n dd-models rollout status deploy/model --timeout=120s
{K} -n dd-tools rollout status deploy/tools --timeout=120s'''),
       [("Agent ready", "pod/unmanaged-agent condition met"), ("Model ready", 'deployment "model" successfully rolled out'), ("Tools ready", 'deployment "tools" successfully rolled out')])
action("Create the model and MCP gateway", "Give this lab its own gateway, model backend and MCP route.", "dd-gateway is Ready.",
       apply("02-gateway.yaml", f'''{K} -n dd-gateway wait gateway/dd-gateway --for=condition=Programmed --timeout=120s
{K} -n dd-gateway rollout status deploy/dd-gateway --timeout=120s'''),
       [("Gateway ready", 'deployment "dd-gateway" successfully rolled out')])
action("Declare the outside destination", "Put example.com behind a waypoint visible only to dd-agents. No deny policy is attached yet.", "The waypoint is Ready and an ordinary HTTPS request still returns 200.",
       apply("04-egress-path.yaml", f'''{K} -n dd-agents rollout status deploy/dd-egress --timeout=120s
{EXEC} --retry 10 --retry-all-errors --retry-delay 1 -o /dev/null -w 'Outside HTTP %{{http_code}}\\n' https://example.com'''),
       [("Waypoint ready", 'deployment "dd-egress" successfully rolled out'), ("Outside reachable", "Outside HTTP 200")])
action("Prepare test identities", "Generate a lab-local signing key and public JWT policy. The policy is not applied yet.", "The public JWT policy is ready. The private key stays local and Reset removes it.",
       'python3 "$DD/identity.py" setup', [("Signing key ready", "Lab signing key ready")])
action("Select the installed rate limiter", "Create a lab-owned Service pointing to the main rate-limiter ReplicaSet. On this rig the default Service also selects the waypoint limiter, whose separate counter would double the allowance.",
       "dd-rate-limiter selects exactly the main limiter. No platform Deployment is changed.",
       f'''HASH=$({K} -n agentgateway-system get rs -o json | jq -er '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Deployment" and .name == "rate-limiter-enterprise-agentgateway")) | select(.spec.replicas > 0)] | sort_by(.metadata.creationTimestamp) | last | .metadata.labels["pod-template-hash"]')
jq -n --arg hash "$HASH" '{{apiVersion:"v1",kind:"Service",metadata:{{name:"dd-rate-limiter",namespace:"agentgateway-system"}},spec:{{selector:{{app:"rate-limiter","pod-template-hash":$hash}},ports:[{{name:"grpc",port:8083,targetPort:8083}}]}}}}' | {K} apply -f -
{K} -n agentgateway-system get service dd-rate-limiter -o yaml''', [("Dedicated selector", "service/dd-rate-limiter (created|configured|unchanged)"), ("ReplicaSet selector", "pod-template-hash:")])

chapter(2, "Outside destination", "Control access to an outside destination",
        "The pod can currently reach example.com. Deny traffic at its egress waypoint, then repeat the same HTTPS request.",
        "This is destination-scoped egress control. Kindnet accepts but does not enforce NetworkPolicy. Other destinations are outside this chapter's claim.")
action("Without the control", "Fetch example.com through the open waypoint.", "The HTTPS request returns 200.",
       f"{EXEC} -o /dev/null -w 'Outside HTTP %{{http_code}}\\n' https://example.com", [("Outside reachable", "Outside HTTP 200")], watch="app")
action("Add the control", "Deny all traffic handled by this lab's egress waypoint.", "The AuthorizationPolicy is applied.",
       apply("05-egress-deny.yaml", "sleep 2"), [("Egress deny applied", "authorizationpolicy.security.istio.io/outside-deny (created|configured|unchanged)")], watch="app")
action("With the control", "Repeat the HTTPS request and read the waypoint's TCP RBAC counter. A curl failure alone would not prove a policy refusal.",
       "The connection is refused and tcp.rbac.denied is greater than zero.",
       f'''if {EXEC} -o /dev/null https://example.com; then printf 'Unexpected outside access\\n'; exit 1; else printf 'Outside request refused\\n'; fi
{K} -n dd-agents exec deploy/dd-egress -- pilot-agent request GET 'stats?filter=rbac' ''',
       [("Outside refused", "Outside request refused"), ("RBAC evidence", r"tcp\.rbac\.denied: [1-9]\d*")], watch="app")

chapter(3, "Workload identity", "Allow only the gateway to reach the model",
        "An ambient certificate identifies the pod, but no policy yet prevents it from calling the model directly. Add the gateway-only rule to models and tools.",
        "The platform checks the caller's SPIFFE identity. User JWTs do not replace this boundary.")
action("Without the control", "Call the model service directly from the agent pod.", "The model echoes the request with HTTP 200.",
       model(url='http://model.dd-models.svc:8000/v1/chat/completions'), [("Direct model call", "ordinary model request"), ("Accepted", "HTTP 200")], watch="app")
action("Add the control", "Allow only mesh1/ns/dd-gateway/sa/dd-gateway into the model and tool namespaces.", "Both gateway-only policies are applied.",
       apply("06-workload-identity.yaml", "sleep 2"), [("Workload policies", r"(authorizationpolicy.security.istio.io/gateway-only (created|configured|unchanged)[\s\S]*){2}")], watch="app")
action("With the control", "Repeat the direct call, then use the gateway. Read the inbound ztunnel refusal for this workload.", "Direct access is refused, the gateway still returns 200, and the log names unmanaged-agent.",
       f'''if {EXEC} http://model.dd-models.svc:8000/v1/chat/completions -H 'Content-Type: application/json' -d {BODY}; then exit 1; else printf 'Direct model request refused\\n'; fi
{model()}
{K} -n istio-system logs -l app=ztunnel --since=30s --tail=3000 | jq -c 'select(.["src.namespace"] == "dd-agents" and .direction == "inbound" and (.error // "" | contains("policy rejection"))) | {{source:.["src.identity"], destination:.["dst.namespace"], error}}' ''',
       [("Direct call refused", "Direct model request refused"), ("Gateway works", "HTTP 200"), ("Workload named", "spiffe://mesh1/ns/dd-agents/sa/unmanaged-agent"), ("Policy evidence", "allow policies exist, but none allowed")], watch="app")

chapter(4, "Caller identity", "Require a signed user token",
        "The gateway is an allowed workload. Now require the person or application using it to present a token from the lab's issuer, with the right audience.",
        "The same pod gets 401 without a token and 200 with Alice's token. These are different identities at different boundaries.")
action("Without the control", "Call the model through the gateway without a token.", "HTTP 200, because caller authentication is not configured yet.", model(), [("Anonymous call accepted", "HTTP 200")], watch="app")
action("Add the control", "Read the entire public JWT policy, then apply Strict authentication to the lab gateway.", "The policy is Accepted and Attached.",
       f'''cat "$DD_STATE/07-caller-identity.json"
{K} apply -f "$DD_STATE/07-caller-identity.json"
dd_wait_policy caller-identity''', [("Strict mode", '"mode": "Strict"'), ("Caller policy attached", "caller-identity Accepted and Attached")], watch="app")
action("With the control", "Repeat the anonymous request, then present a freshly signed Alice token. Read the gateway's refusal log.", "401 with no token, 200 with Alice's token, and a recorded authentication failure.",
       f'''{model()}
ALICE=$(python3 "$DD/identity.py" token --user alice)
{model(True)}
{K} -n dd-gateway logs deploy/dd-gateway --since=15s | grep 'http.status=401' ''',
       [("Anonymous refused", "HTTP 401"), ("Alice accepted", "HTTP 200"), ("Authentication evidence", "authentication failure: no bearer token found")], watch="app")

chapter(5, "Tool permissions", "Give Alice only the read tool",
        "The MCP server offers read_status and delete_records. The latter is a harmless dry run. First call it as Alice, then restrict tool access using her signed group claim.",
        "The gateway filters discovery and refuses the call before it reaches the tool server. Hiding a tool alone would not be enough.")
action("Without the control", "List the tools as Alice and call the dry-run deletion tool.", "Both tools are listed and the dry run is accepted.",
       '''ALICE=$(python3 "$DD/identity.py" token --user alice)
dd_mcp "$ALICE" tools/list
dd_mcp "$ALICE" tools/call '{"name":"delete_records","arguments":{}}' ''',
       [("Read tool listed", '"name":"read_status"'), ("Delete tool listed", '"name":"delete_records"'), ("Dry run accepted", "Dry run accepted")], watch="app")
action("Add the control", "Permit read_status for authenticated callers and all tools only for the admin group.", "The tool policy is Accepted and Attached.",
       apply("08-tool-permissions.yaml", "dd_wait_policy tool-permissions"), [("Tool policy attached", "tool-permissions Accepted and Attached")], watch="app")
action("With the control", "List Alice's tools, repeat her deletion call, then confirm the admin can still make the dry-run call. Read the refusal log.", "Alice sees only read_status and gets Unknown tool for delete_records. Carol's dry run still works.",
       f'''ALICE=$(python3 "$DD/identity.py" token --user alice); ADMIN=$(python3 "$DD/identity.py" token --user carol --group admin)
printf 'Reader tools\\n'; dd_mcp "$ALICE" tools/list
printf 'Reader call\\n'; dd_mcp "$ALICE" tools/call '{{"name":"delete_records","arguments":{{}}}}'
printf 'Admin call\\n'; dd_mcp "$ADMIN" tools/call '{{"name":"delete_records","arguments":{{}}}}'
{K} -n dd-gateway logs deploy/dd-gateway --since=15s | grep 'Unknown tool: delete_records' ''',
       [("Read tool remains", '"name":"read_status"'), ("Reader refused", "Unknown tool: delete_records"), ("Admin allowed", "Dry run accepted"), ("Caller recorded", "jwt.sub=alice")], watch="app")
steps["5"]["blocks"][-1]["checks"].append({"label": "Delete tool hidden", "match": '"name":"delete_records"', "absent": True, "from": "Reader tools", "to": "Reader call"})

chapter(6, "Personal data", "Remove personal data before the model",
        "Send a sample email address. First the model receives it unchanged. Add request masking and read what the model actually received on the second call.",
        "Masking is not a refusal. HTTP 200 is expected. The upstream log, not just the response, proves the email was removed. Regex masking does not classify every kind of personal data.")
action("Without the control", "Send the specimen email through the gateway.", "The echo model returns alice@example.test unchanged.",
       'ALICE=$(python3 "$DD/identity.py" token --user alice)\n' + model(True, PROMPT), [("Unmasked email", "Contact alice@example.test for the sample."), ("Accepted", "HTTP 200")], watch="app")
action("Add the control", "Mask recognised email addresses on the model route. The backend deliberately uses the singular AI provider shape.", "The prompt guard is Accepted and Attached.",
       apply("09-content.yaml", "dd_wait_policy mask-personal-data"), [("Mask policy attached", "mask-personal-data Accepted and Attached")], watch="app")
action("With the control", "Send the same prompt. Read the last received_prompt from the model's own log, then the gateway's guardrail counter.", "The model receives <EMAIL_ADDRESS>, with HTTP 200. The Mask check counter increases.",
       'ALICE=$(python3 "$DD/identity.py" token --user alice)\n' + model(True, PROMPT) + f'''\nprintf 'Upstream evidence\\n'
{K} -n dd-models logs deploy/model --tail=30 | jq -Rsc '[split("\\n")[] | fromjson? | select(has("received_prompt"))] | last'
{METRICS}''',
       [("Request preserved", "HTTP 200"), ("Upstream masked", r'"received_prompt":\s*"Contact <EMAIL_ADDRESS> for the sample\."'), ("Guardrail evidence", r'agentgateway_guardrail_checks_total\{phase="Request",action="Mask"\} [1-9]')], watch="app")

chapter(7, "Request rate", "Limit requests per caller",
        "Send six requests. Add a global limit of three model requests per minute per signed subject, then repeat the requests and make a request as someone else.",
        "Each demonstration burst uses fresh Alice and Bob subjects so rerunning the step has a fresh bucket. It sends at most twenty requests. No model spend is involved.")
params = [{"name": "N", "label": "Requests", "default": 6, "min": 5, "max": 20}]
action("Without the control", "Send the bounded burst with no rate policy.", "All Alice requests and Bob's request return 200.",
       'dd_burst open "${N:-6}"', [("All accepted", r"Alice totals: accepted=\d+ limited=0"), ("Bob accepted", "Bob request: HTTP 200")], params=params, watch="app")
action("Add the control", "Apply the per-subject descriptor and policy. Wait for the limiter to accept the current config generation.", "The policy is attached and the limiter reports ACCEPTED.",
       apply("10-rate.yaml", "dd_wait_policy per-person-rate\ndd_wait_rate"), [("Rate policy attached", "per-person-rate Accepted and Attached"), ("Limiter loaded", "dd-per-person ACCEPTED at current generation")], watch="app")
action("With the control", "Repeat the burst and read the gateway's 429 evidence.", "Alice gets 429 after her allowance. Bob still gets 200.",
       'dd_burst limited "${N:-6}"\n' + METRICS,
       [("Alice limited", "Alice request \\d+: HTTP 429"), ("Bob unaffected", "Bob request: HTTP 200"), ("Rate metric", r'agentgateway_requests_total\{[^\n]*status="429",reason="DirectResponse"[^\n]*\} [1-9]')], params=params, watch="app")

chapter(8, "Detection", "Read the recorded outcomes by caller",
        "The platform has already recorded refusals. Add caller identity to the gateway metrics and generate another bounded burst so the new labels have something to show.",
        "Detection does not refuse requests. The live board combines gateway counters, the waypoint's RBAC counter and retained ztunnel logs. Mask checks and HTTP refusals are labelled separately.")
action("Before adding caller labels", "Read the gateway's own metrics. Status and reason are already present.", "401, 429 and Mask evidence are visible without changing enforcement.",
       METRICS, [("401 recorded", 'status="401"'), ("429 recorded", 'status="429"'), ("Mask recorded", "agentgateway_guardrail_checks_total")], watch="app")
action("Add caller labels", "Attach a metrics attribute based on the validated JWT subject.", "The identity-metrics policy is Accepted and Attached.",
       apply("11-detection.yaml", "dd_wait_policy identity-metrics"), [("Metrics policy attached", "identity-metrics Accepted and Attached")], watch="app")
action("With caller labels", "Generate fresh rate refusals and read the metrics again. Watch Detection become Observing on the App tab.", "The 429 samples carry Alice's subject, while Bob succeeds. Earlier unlabelled samples may remain until the gateway restarts.",
       'dd_burst limited 6\n' + METRICS,
       [("Refusal still enforced", "HTTP 429"), ("Bob still works", "Bob request: HTTP 200"), ("Caller-labelled sample", 'caller="alice-')], watch="app")

cell("markdown", "## Reset\n\nRemove only this lab's footprint. The console also checks that the resources are gone.")
cell("code", f'''{K} delete namespace dd-agents dd-models dd-tools dd-gateway --ignore-not-found --wait=true --timeout=180s
{K} -n agentgateway-system delete service dd-rate-limiter --ignore-not-found
rm -f "$DD_STATE/private.pem" "$DD_STATE/07-caller-identity.json"''')

notebook = {"cells": cells, "metadata": {"kernelspec": {"display_name": "Bash", "language": "bash", "name": "bash"}, "language_info": {"name": "bash"}}, "nbformat": 4, "nbformat_minor": 5}
spec = {"intro": "Runs on kind-mesh1 with Enterprise agentgateway and ambient Istio. The model simulator runs locally, so there are no model API charges. Each control has a before/after check. Egress is scoped to example.com; masking and detection are not refusal controls. Run the chapters in order, then Reset lab to remove its footprint.",
        "app": {"label": "Layers of defence, live", "url": "/defence/live", "hint": "Policies, refusal evidence and masking checks from mesh1."}, "steps": steps}
(ROOT / "demo-13-defence-in-depth.ipynb").write_text(json.dumps(notebook, ensure_ascii=True, indent=1) + "\n")
(ROOT / "demo-console/present/demo-13.json").write_text(json.dumps(spec, ensure_ascii=True, indent=2) + "\n")
print(f"Built {len(steps)} chapters, {sum(len(s['blocks']) for s in steps.values())} actions")
