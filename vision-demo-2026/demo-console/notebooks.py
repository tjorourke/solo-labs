"""Turn a demo notebook into console pages.

The demos have always lived in `vision-demo-2026/*.ipynb`, which is a fine place
to build them and a poor place to present them. This reads a notebook, splits it
on its `##` headings, and serves each section as a card and a page: the prose and
diagrams the notebook already carries, the cell's bash shown and copyable, and a
Run button that executes that exact cell and streams the output back.

The client never sends bash. It sends a notebook id, a step id and a block index,
and the server runs what the notebook holds at that position.

    DEMOS   the registry: which notebooks the console offers
    load()  parse one into Demo/Step/Block
    run()   execute one block, streaming ndjson events
"""
from __future__ import annotations

import html
import json
import os
import re
import subprocess
import threading
import fcntl
from contextlib import contextmanager
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NOTEBOOKS = ROOT.parent

# Every demo the console knows about. Adding one is an entry here: the notebook,
# how it is billed, the env its cells expect, the UIs it is watched in, and which
# of its sections are housekeeping rather than story.
ISTIO_ENV = """
export CTX="${CTX:-kind-mesh1}" ISTIO_NS="${ISTIO_NS:-istio-system}" TD="${TD:-mesh1}"
export ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl-1.30.3-solo}"
export HUB="${HUB:-us-docker.pkg.dev/soloio-img/istio}" TAG="${TAG:-1.30.3-solo}"
export HREPO="${HREPO:-oci://us-docker.pkg.dev/soloio-img/istio-helm}" HVER="${HVER:-1.30.3-solo}"
"""

# demo-7's Connect cell is dropped (the console buttons replace it), so its env lives
# here. Each block runs in its own shell, so the personas §3 mints are minted again
# for every block; they are signed locally and cost nothing.
LLM_ENV = """
export CTX="${CTX:-kind-mesh1}" NS="${NS:-agentgateway-system}"
kubectl() { command kubectl --context "$CTX" "$@"; }
export -f kubectl
export GATEWAY="${GATEWAY:-$(kubectl -n $NS get gateway ai-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)}"
. demo-scripts/scripts/llm-gateway-helpers.sh
if [ -f demo-scripts/.jwt/private.pem ]; then
  _mint() {  # <user> <group> <team> <businessUnit>
    printf '{"iss":"https://idp.demo.example/","sub":"%s@corp.example","group":"%s","groups":["%s"],"team":"%s","businessUnit":"%s","exp":4070908800}' \\
      "$1" "$2" "$2" "$3" "$4" | ./demo-scripts/scripts/mint-jwt.sh -
  }
  export ALICE=$(_mint alice engineering payments retail-banking)
  export BOB=$(_mint bob finance fraud-detection risk)
  export CAROL=$(_mint carol engineering quant-research markets)
fi
"""

GLOO_UI = {
    "id": "gloo-ui", "label": "Open Gloo UI",
    "note": "service graph", "url": "http://localhost:8091",
    "context": "kind-mesh1", "namespace": "gloo-mesh",
    "service": "gloo-mesh-ui", "local": 8091, "remote": 8090,
}


def _solo_ui(path: str, id_: str, label: str, note: str) -> dict:
    """The Solo Enterprise UI: one port-forward, several views."""
    return {
        "id": id_, "label": label, "note": note,
        "url": f"http://localhost:8095{path}",
        "context": "kind-mesh1", "namespace": "solo-cost",
        "service": "solo-enterprise-ui", "local": 8095, "remote": 80,
    }


COST_UI = _solo_ui("/age/cost-management", "cost", "Open Cost Management", "LLM spend")

# demo-4's cells run from demo-scripts/agentregistry after its Connect step, which
# the console does for every action. Connect never resets anything.
AGENTREGISTRY_ENV = """
cd demo-scripts/agentregistry
source scripts/connect.sh >/dev/null 2>&1
"""


def _ingress_url(prefix: str, id_: str, label: str, note: str) -> dict:
    """AgentRegistry and kagent UIs are on ar-ingress through sslip.io, so no
    port-forward: the URL is resolved from the Gateway address when opened."""
    return {"id": id_, "label": label, "note": note, "ingress": prefix,
            "context": "kind-mesh1", "namespace": "agentgateway-system", "gateway": "ar-ingress"}


AR_UI = _ingress_url("agentregistry", "ar-ui", "Open AgentRegistry UI", "catalogue and deployments")
KAGENT_UI = _ingress_url("kagent", "kagent-ui", "Open kagent UI", "chat, tracing, access policies (admin-user / password)")

# substrate-lab.sh sources substrate-lib.sh, which pins kind-substrate and moves to the suite root.
SUBSTRATE_ENV = """
. demo-scripts/substrate-lab.sh
"""

INFERENCE_ENV = """
export CTX="${CTX:-kind-inference}" NS="${NS:-inference}"
. demo-scripts/scripts/inference-helpers.sh
"""

REST_MCP_ENV = """
export CTX="${CTX:-kind-mesh1}" NS="${NS:-agentgateway-system}"
kc() { kubectl --context "$CTX" "$@"; }
export -f kc
export LB="${LB:-$(kc -n $NS get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)}"
mcp() { python3 demo-scripts/mcp-client.py "$@"; }
export -f mcp
"""

# Sections that are housekeeping, not part of the pitch. They move behind Rig
# controls instead of becoming story cards.
CHORE_IDS = {"connect", "reset", "tear-down-and-move-on", "tear-down"}

DEMOS = {
    "demo-13": {
        "domain": "agentic",
        "notebook": "demo-13-defence-in-depth.ipynb",
        "kicker": "KAGENT · AGENTGATEWAY · ISTIO",
        "short": "Defence in depth",
        "title": "Layers of defence for an agent",
        "blurb": "Run an incident-response agent in kagent. Watch it close unresolved incidents, then use agentgateway and Istio policies to restrict its permissions and record refusals.",
        "clusters": ["kind-mesh1"],
        "needs": "mesh1 with Enterprise kagent 0.4.3, Enterprise agentgateway 2026.8.2 and ambient Istio. Uses the installed Anthropic credential. Docker builds the incident-tools image into the local registry. Model calls are real and billable.",
        "show_vars": ["DD", "DD_TOOLS", "DD_STATE"],
        "helpers": ["demo-scripts/defence/helpers.sh"],
        "env": '''
export DD=demo-scripts/defence DD_TOOLS=http://tools.dd-gateway.svc/mcp
export DD_STATE="${TMPDIR:-/tmp}/defence-lab"
. "$DD/helpers.sh"
if [ -f "$DD_STATE/private.pem" ]; then
  export ALICE=$(python3 "$DD/identity.py" token --user alice)
  export ADMIN=$(python3 "$DD/identity.py" token --user carol --group admin)
fi
''',
        "consoles": [KAGENT_UI],
    },
    "demo-1": {
        # Shown with their current values on the Commands tab.
        "show_vars": ["CLUSTER1", "CLUSTER2", "CTX"],
        "domain": "connectivity",
        "notebook": "demo-1-istio-ambient-multicluster.ipynb",
        "kicker": "ISTIO · MULTICLUSTER",
        "short": "Multicluster failover",
        "title": "Ambient multicluster failover",
        "blurb": "Deploy Bookinfo on two clusters. Connect the meshes, publish a shared service and test failover when local replicas stop.",
        "clusters": ["kind-mesh1", "kind-mesh2"],
        "needs": "The ambient platform must already be installed on both clusters. The status badge checks Kubernetes API access.",
        "env": """
export CLUSTER1="${CLUSTER1:-kind-mesh1}" CLUSTER2="${CLUSTER2:-kind-mesh2}"
export ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl-1.30.3-solo}"
""",
        "consoles": [GLOO_UI, COST_UI],
    },
    "demo-2": {
        # Shown with their current values on the Commands tab.
        "show_vars": ["CTX", "ISTIO_NS", "TD", "HUB", "TAG", "HREPO", "HVER"],
        "domain": "connectivity",
        "notebook": "demo-2-istio-ztunnel-l4.ipynb",
        "kicker": "ISTIO AMBIENT · L4 IDENTITY",
        "short": "Ambient L4 identity",
        "title": "Ambient L4 workload identity with ztunnel",
        "blurb": "Use workload certificates to control access at L4. Compare ServiceAccount identity with signed per-pod claims.",
        "clusters": ["kind-mesh1"],
        "needs": "The ambient platform must already be installed on mesh1. The status badge checks Kubernetes API access.",
        "env": ISTIO_ENV,
        "consoles": [GLOO_UI],
    },
    "demo-3": {
        # Shown with their current values on the Commands tab.
        "show_vars": ["CTX", "ISTIO_NS", "TD", "HUB", "TAG", "HREPO", "HVER"],
        "domain": "connectivity",
        "notebook": "demo-3-istio-waypoint-l7.ipynb",
        "kicker": "ISTIO · WAYPOINT POLICIES",
        "short": "Waypoint policies",
        "title": "L7 policies with waypoints",
        "blurb": "Add an agentgateway waypoint to the petshop application. Apply JWT authorisation, canary routing and workload-based rate limits.",
        "clusters": ["kind-mesh1"],
        "needs": "Ambient, the waypoint controller and Keycloak must already be installed on mesh1.",
        "env": ISTIO_ENV,
        "consoles": [GLOO_UI],
    },
    "demo-4": {
        # Shown with their current values on the Commands tab.
        "show_vars": ["PROJECT_ROOT", "CTX"],
        # connect.sh logs in and frees ports, so resolve from lib.sh alone.
        "show_env": "cd demo-scripts/agentregistry && . scripts/lib.sh >/dev/null 2>&1",
        "domain": "agentic",
        "notebook": "demo-4-agentics-vision.ipynb",
        "kicker": "AGENTREGISTRY · BUILD AN AGENT",
        "short": "Build an agent",
        "title": "Build, ship and govern an ADK agent",
        "blurb": "Scaffold an ADK agent from the approved catalogue, give it MCP tools, deploy it to kagent, restrict its tools with an AccessPolicy, then run the same agent on AWS Bedrock AgentCore.",
        "clusters": ["kind-mesh1"],
        "needs": "AgentRegistry, kagent, Keycloak and Kyverno must be installed on mesh1 (Reset scales them up if they are parked). The AgentCore chapters also need an AWS SSO session for the profile in demo-scripts/agentregistry/.env.aws.",
        "env": AGENTREGISTRY_ENV,
        "consoles": [KAGENT_UI, AR_UI],
        # 7 and 8 are their own labs now (REST to MCP, and the quadratic on the
        # Token economics page). Setup and teardown are the Reset control.
        "drop": ["7", "8", "reset-teardown", "setup"],
    },
    "demo-6": {
        # Shown with their current values on the Commands tab.
        # Helper files whose functions the Commands tab shows when a step calls them.
        "helpers": ["demo-scripts/scripts/inference-helpers.sh"],
        "show_vars": ["CTX", "NS"],
        "domain": "agentic",
        "notebook": "demo-6-inference.ipynb",
        "kicker": "AGENTGATEWAY · INFERENCE ROUTING",
        "short": "Inference routing",
        "title": "Inference routing on KV cache and queue depth",
        "blurb": "Route requests across a self-hosted model pool on live load. Watch the Endpoint Picker follow KV-cache use and queue depth, then give interactive traffic priority over batch.",
        "clusters": ["kind-inference"],
        "needs": "The kind-inference cluster must be up (agentgateway-inference-routing-kind: ./scripts/quick.sh up). No GPU: the model servers are simulators with pinned gauges.",
        "env": INFERENCE_ENV,
        "consoles": [],
        # The console connects and resets itself; the helpers live in a sourced file.
        "drop": ["connect", "two-commands-we-reuse", "reset"],
    },
    "demo-12": {
        # Shown with their current values on the Commands tab.
        # Helper files whose functions the Commands tab shows when a step calls them.
        "helpers": ["demo-scripts/substrate-lab.sh", "demo-scripts/substrate-lib.sh"],
        "show_vars": ["CTX", "SUBSTRATE_YAML"],
        "domain": "agentic",
        "notebook": "demo-12-agent-substrate.ipynb",
        "kicker": "KAGENT · AGENT SUBSTRATE",
        "short": "Agent Substrate",
        "title": "Agent Substrate: agents that sleep between turns",
        "blurb": "Define a worker pool, put an agent and a harness on it, read the ActorTemplate kagent renders, then watch a conversation get snapshotted and resume, and load the pool until it runs out of workers.",
        "clusters": ["kind-substrate"],
        "needs": "The kind-substrate cluster with Solo Enterprise for kagent 0.5.6 and Agent Substrate (demo-scripts/substrate-cluster.sh). Turns make live Anthropic calls.",
        "env": SUBSTRATE_ENV,
        "consoles": [],
    },
    "demo-7": {
        # Shown with their current values on the Commands tab.
        # Helper files whose functions the Commands tab shows when a step calls them.
        "helpers": ["demo-scripts/scripts/llm-gateway-helpers.sh"],
        "show_vars": ["NS", "GATEWAY", "CTX"],
        "domain": "agentic",
        "notebook": "demo-7-llm-gateway.ipynb",
        "kicker": "AGENTGATEWAY · MODEL ACCESS",
        "short": "Model access",
        "title": "Model access with agentgateway",
        "blurb": "Route model requests through a gateway. Test provider failover, user permissions, token budgets and MCP tool access.",
        "clusters": ["kind-mesh1"],
        "needs": "The AI gateway, local model simulators, MCP server and demo signing keys must already be installed. Reset clears the lab configuration; it does not install the platform.",
        "env": LLM_ENV,
        "consoles": [
            _solo_ui("/age/", "solo-ui", "Open Solo UI", "dashboard, live traffic per model"),
            _solo_ui("/age/tracing", "tracing", "Open Tracing", "one span per request"),
            COST_UI,
        ],
        # "Open console" is what the buttons above replace, so it is not a step.
        "drop": ["open-console"],
    },
    "demo-11": {
        # Shown with their current values on the Commands tab.
        "show_vars": ["LB", "NS", "CTX"],
        "domain": "agentic",
        "notebook": "demo-11-rest-to-mcp.ipynb",
        "kicker": "AGENTGATEWAY · REST TO MCP",
        "short": "REST to MCP",
        "title": "Turn a REST API into MCP tools, then compose them",
        "blurb": "Expose every operation of a REST API as an MCP tool from its OpenAPI spec, with no code. Then chain those calls into new workflow tools on a new MCP endpoint, and let a model use them.",
        "clusters": ["kind-mesh1"],
        "needs": "Enterprise agentgateway and the ar-ingress Gateway must be installed on mesh1. The last chapter makes a live Anthropic call.",
        "env": REST_MCP_ENV,
        "consoles": [],
    },
}

# Every block runs with the demo's Connect env already set, so a step works on its
# own without the presenter having run Connect first.
BASE_ENV = f"""
export SECRETS_FILE="${{SECRETS_FILE:-{ROOT.parent / "secrets.env"}}}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a
"""


def preamble(demo_id: str) -> str:
    return BASE_ENV + DEMOS.get(demo_id, {}).get("env", "")


_display_cache: dict[str, tuple[float, dict]] = {}


def display_values(demo_id: str) -> dict:
    """Current values of the lab's show_vars, resolved from its own environment.
    Cached briefly; an unreachable cluster just leaves the names unexpanded."""
    names = DEMOS.get(demo_id, {}).get("show_vars", [])
    if not names:
        return {}
    hit = _display_cache.get(demo_id)
    if hit and time.monotonic() - hit[0] < 120:
        return hit[1]
    env = DEMOS[demo_id].get("show_env") or preamble(demo_id)
    probe = env + "\n" + "".join(f'printf "%s=%s\\n" {n} "${{{n}}}"\n' for n in names)
    try:
        out = subprocess.run(["bash", "-c", probe], cwd=str(NOTEBOOKS), capture_output=True,
                             text=True, timeout=25).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    values = {}
    for line in out.splitlines():
        k, _, v = line.partition("=")
        if k in names and v:
            values[k] = v
    _display_cache[demo_id] = (time.monotonic(), values)
    return values


_FUNC = re.compile(r"^([A-Za-z_][\w-]*)\(\)\s*\{")


def _helper_defs(demo_id: str) -> dict[str, tuple[str, str]]:
    """Every shell function in the lab's helper files: name -> (file, source)."""
    defs: dict[str, tuple[str, str]] = {}
    for rel in DEMOS.get(demo_id, {}).get("helpers", []):
        path = NOTEBOOKS / rel
        if not path.is_file():
            continue
        lines = path.read_text().split("\n")
        i = 0
        while i < len(lines):
            m = _FUNC.match(lines[i])
            if not m:
                i += 1
                continue
            start = i
            # a one-liner closes on its own line; otherwise the body ends at a bare "}"
            if not (lines[i].rstrip().endswith("}") and lines[i].count("{") == lines[i].count("}")):
                while i + 1 < len(lines) and lines[i + 1].rstrip() != "}":
                    i += 1
                i += 1
            defs.setdefault(m.group(1), (rel, "\n".join(lines[start:i + 1])))
            i += 1
    return defs


def helpers_for(demo_id: str, script: str) -> list[tuple[str, str, str]]:
    """The helper functions a step calls, and the ones those call, in call order.
    Shown under the step's commands so nothing it runs is hidden."""
    defs = _helper_defs(demo_id)
    if not defs:
        return []
    def calls(src: str) -> list[str]:
        code = "\n".join(l.split(" #")[0] for l in src.split("\n") if not l.lstrip().startswith("#"))
        # only where a command can start: line start, or after ; | & ( $( then do else !
        lead = r"(?:^|[;|&(!]|\$\(|\b(?:then|do|else)\b)[ \t]*"
        return [n for n in defs if re.search(lead + re.escape(n) + r"(?=[ \t]|$|;|\))", code, re.M)]
    seen: list[str] = []
    queue = calls(script)
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.append(name)
        queue += [n for n in calls(defs[name][1].split("\n", 1)[-1]) if n not in seen]
    return [(n, *defs[n]) for n in seen]


def expand_for_display(demo_id: str, script: str) -> str:
    """The script as the Commands tab shows it: environment variables replaced by
    their values. Display only; what runs is unchanged. A variable the script
    assigns itself, a ${VAR:-default} form, and anything inside a quoted heredoc
    (where bash would not expand it either) are left as written."""
    values = {k: v for k, v in display_values(demo_id).items()
              if not re.search(rf"(^|[\s;(]){k}=", script, re.M)}
    if not values:
        return script
    pat = re.compile(r"\$\{(" + "|".join(values) + r")\}|\$(" + "|".join(values) + r")\b")
    out, quoted = [], None
    for line in script.split("\n"):
        if quoted:
            out.append(line)
            if line.strip() == quoted:
                quoted = None
            continue
        out.append(pat.sub(lambda m: values[m.group(1) or m.group(2)], line))
        m = re.search(r"<<-?\s*'(\w+)'", line)
        if m:
            quoted = m.group(1)
    return "\n".join(out)


_cluster_status_cache = {}
_cluster_status_lock = threading.Lock()


def cluster_status(demo_id: str) -> dict:
    """Check the contexts this lab actually uses, independently of the routing feed."""
    if demo_id not in DEMOS:
        raise ValueError("Unknown lab")
    contexts = ([os.environ.get("CLUSTER1", "kind-mesh1"), os.environ.get("CLUSTER2", "kind-mesh2")]
                if demo_id == "demo-1" else list(DEMOS[demo_id].get("clusters") or [os.environ.get("CTX", "kind-mesh1")]))
    key = tuple(contexts)
    with _cluster_status_lock:
        cached = _cluster_status_cache.get(key)
        if cached and time.monotonic() - cached[0] < 10:
            return cached[1]
        rows = []
        for context in contexts:
            try:
                probe = subprocess.run(["kubectl", "--context", context, "get", "--raw=/readyz", "--request-timeout=3s"],
                                       capture_output=True, text=True, timeout=5)
                ready = probe.returncode == 0 and probe.stdout.strip() == "ok"
            except (OSError, subprocess.TimeoutExpired):
                ready = False
            rows.append({"context": context, "name": context.removeprefix("kind-"), "ready": ready})
        result = {"ready": all(r["ready"] for r in rows), "clusters": rows}
        _cluster_status_cache[key] = (time.monotonic(), result)
        return result


LOCKFILE = NOTEBOOKS / ".demo-console.lock"


@contextmanager
def file_lock(blocking: bool = False):
    """Context manager providing a cross-process exclusive lock using fcntl.flock.

    Non-blocking mode raises BlockingIOError if the lock cannot be acquired.
    """
    fh = LOCKFILE.open("a+")
    try:
        flags = fcntl.LOCK_EX
        if not blocking:
            flags |= fcntl.LOCK_NB
        fcntl.flock(fh.fileno(), flags)
        yield fh
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()


# Shared between the three Istio notebooks, which carry the same Connect section.
CONNECT_RULES = [
    (
        " (Reloaded the notebook? Run just this to get your env back.)",
        "",
    ),
    (
        "Watch traffic in the **Gloo UI** service graph. Open it once and leave it "
        "running (I open the URL in the Cursor browser):",
        "Watch traffic in the **Gloo UI** service graph. **Open Gloo UI** at the top of "
        "the page starts it and opens the tab. Open it once and leave it running.",
    ),
]

PRESENT = {
    # The notebook numbers only its scenarios; the console numbers every chapter.
    "demo-6": [
        ("## The model pool", "## 1. The model pool"),
        ("## The Endpoint Picker (EPP)", "## 2. The Endpoint Picker (EPP)"),
        ("## 1. KV-cache-aware routing", "## 3. KV-cache-aware routing"),
        ("## 2. Queue-aware routing", "## 4. Queue-aware routing"),
        ("## 3. Prefix-cache affinity", "## 5. Prefix-cache affinity"),
        ("## 4. Serving priority with InferenceObjective", "## 6. Serving priority with InferenceObjective"),
    ],
    "demo-4": [
        # The intro's plan still lists 7 and 8, which are their own labs in the console.
        ("7. **Demonstrate OpenAPI \u2192 MCP** \u2014 point agentgateway at the public Swagger Petstore spec and every REST operation becomes a governed MCP tool, with no code written and no server built.\n8. **Demonstrate MCP Code Mode** \u2014 ask for the roots of `x\u00b2 \u2212 5x + 6 = 0`. In standard mode the model makes eleven sequential tool calls at roughly 8,400 tokens. Flip `toolMode` to `Code` and it writes one short program instead: one turn, about 650 tokens, same answer.\n", ""),
        ("9. **Deploy the same agent", "7. **Deploy the same agent"),
        ("*Setup \u2014 consoles, `arctl` login and reset \u2014 is at the bottom of this notebook. Run it first.*", "*Reset is on the last chapter and under Environment and reset.*"),
        (
            "You never paste one: `connect.sh` stamps it from the cluster's `kagent-anthropic` Secret, "
            "and §3 sources `connect.sh` before running.",
            "You never paste one: it is stamped from the cluster's `kagent-anthropic` Secret.",
        ),
        (
            "It's interactive, so it runs in a **terminal**, not a cell. Paste all three lines into a fresh terminal:\n\n"
            "```bash\n# from the folder that holds this notebook (the one containing demo-scripts/)\n"
            "source demo-scripts/agentregistry/scripts/connect.sh\narctl run ./agentdemo\n```\n\n"
            "The `source` line is the same Connect step the notebook ran: it puts `arctl` on PATH and re-stamps the "
            "model key into `agentdemo/.env` if a re-scaffold emptied it. Note the directory: the notebook cells sit in "
            "`demo-scripts/agentregistry/`, but the agent project scaffolds at the suite root (`$PROJECT_ROOT`), so "
            "`./agentdemo` resolves from the suite root. From anywhere else, `arctl run \"$PROJECT_ROOT/agentdemo\"` "
            "works once connected.",
            "It is interactive, so it runs in a **terminal**, not on this page. **Background** on this chapter has the "
            "lines to paste.",
        ),
        (
            "> `ask.sh` mints an OIDC token *inside* the cluster (as `admin-user`) and calls the agent's A2A endpoint "
            "through kagent, so the ask behaves the same in a terminal and in a cell.",
            "> Each ask mints an OIDC token *inside* the cluster (as `admin-user`) and calls the agent's A2A endpoint "
            "through kagent.",
        ),
        (
            "`ask.sh` prints the tool-call trace pulled from the A2A response",
            "The output shows the tool-call trace pulled from the A2A response",
        ),
        (
            "`accesspolicy-on.sh` applies the AccessPolicy, labels the MCP server for the waypoint (the kmcp "
            "translator provisions the waypoint Gateway + route), and restarts the agent so it re-lists through the "
            "waypoint.",
            "The registry already labelled the MCP server for the waypoint when it deployed it, so kmcp has "
            "provisioned the waypoint Gateway and route. The policy you apply next is enforced there.",
        ),
        (
            "`ac-invoke.sh` waits for the runtime to be **READY** first",
            "The step waits for the runtime to be **READY** first",
        ),
    ],
    "demo-1": [
        (
            "`setup.sh` has already installed Solo ambient on both clusters, sharing a "
            "single root CA, so they trust each other.",
            "Solo ambient is already installed on both clusters, sharing a single root CA, "
            "so they trust each other.",
        ),
        (
            " (Reloaded the notebook? Run just this to get your env back.)",
            "",
        ),
        (
            "Watch traffic in the **Gloo UI** service graph. Open it once and leave it "
            "running (I open the URL in the Cursor browser):",
            "Watch traffic in the **Gloo UI** service graph. **Open Gloo UI** at the top of "
            "the page starts it and opens the tab. Open it once and leave it running.",
        ),
        (
            "```\n./demo-scripts/consoles.sh\n```\n\n"
            "| Console | URL |\n|---|---|\n"
            "| Gloo UI (service graph) | http://localhost:8091 |\n"
            "| Cost Management (LLM spend, §1.9) | http://localhost:8095/age/cost-management |\n",
            "",
        ),
        (
            "On this demo `setup.sh` already created it, so `expose` is a no-op.",
            "On this demo it already exists, so `expose` is a no-op.",
        ),
        (
            "`setup.sh` already installed **Cost Management** (the Solo Enterprise UI + "
            "bundled ClickHouse) on mesh1 and seeded it",
            "**Cost Management** (the Solo Enterprise UI + bundled ClickHouse) is already "
            "installed on mesh1, seeded",
        ),
        (
            "**Open it:** start the port-forward with `./demo-scripts/consoles.sh` (it also "
            "opens the browser), then go to:\n\nhttp://localhost:8095/age/cost-management",
            "**Open it:** **Open Cost Management** at the top of this page.",
        ),
        (
            "\nFull reference: `demo-scripts/yaml-cost/budget-dimensions.values.yaml`.",
            "",
        ),
    ],
    "demo-2": CONNECT_RULES + [
        (
            "```\n./demo-scripts/consoles.sh\n```\n\n"
            "| Console | URL |\n|---|---|\n"
            "| Gloo UI (service graph) | http://localhost:8091 |\n",
            "",
        ),
    ],
    "demo-3": CONNECT_RULES + [
        (
            "```\n./demo-scripts/consoles.sh\n```\n\n"
            "| Console | URL |\n|---|---|\n"
            "| Gloo UI (service graph) | http://localhost:8091 |\n",
            "",
        ),
        (
            "`setup.sh` already installed the control plane, so this just deploys the app, "
            "creates the waypoint and points the namespace at it.",
            "The control plane is already installed, so this just deploys the app, creates "
            "the waypoint and points the namespace at it.",
        ),
        (
            "Keycloak (from `setup.sh`, realm `petshop`,",
            "Keycloak (realm `petshop`,",
        ),
    ],
    "demo-7": [
        (
            "Open it with `./demo-scripts/consoles.sh`, then:",
            "Open it with **Open Solo UI** at the top of this page, then:",
        ),
        (
            "Open it with `./demo-scripts/consoles.sh`, then "
            "http://localhost:8095/age/cost-management (pick",
            "Open it with **Open Cost Management** at the top of this page (pick",
        ),
        (
            "Reset this demo with the Reset cell near the top. Tear the platform down with "
            "`./demo-scripts/llm-gateway.sh teardown`.",
            "Reset this demo with the Reset control at the top of the page.",
        ),
    ],
}


def _present(src: str, demo_id: str, fired: set[int]) -> str:
    for i, (find, replace) in enumerate(PRESENT.get(demo_id, [])):
        if find in src:
            src = src.replace(find, replace)
            fired.add(i)
    return src


# ── model ────────────────────────────────────────────────────────────────────
@dataclass
class Block:
    kind: str           # "md" | "code"
    html: str = ""      # rendered, for md
    source: str = ""    # raw bash, for code


@dataclass
class Step:
    id: str             # "1.1", "connect", "reset"
    num: str            # "1.1" or "" for the unnumbered ones
    title: str
    blurb: str
    blocks: list[Block] = field(default_factory=list)

    @property
    def label(self) -> str:
        return f"{self.num} · {self.title}" if self.num else self.title

    @property
    def code_blocks(self) -> int:
        return sum(1 for b in self.blocks if b.kind == "code")


@dataclass
class Demo:
    id: str
    kicker: str
    title: str
    blurb: str
    clusters: list[str]
    intro_html: str
    steps: list[Step]
    rules_fired: set[int] = field(default_factory=set)

    def step(self, sid: str) -> Step | None:
        return next((s for s in self.steps if s.id == sid), None)

    @property
    def story(self) -> list[Step]:
        """The demo itself, in order. Demo 7 ends on an unnumbered section, so
        this is what is left after the chores, not what carries a number."""
        return [s for s in self.steps if s.id not in CHORE_IDS]

    @property
    def chores(self) -> list[Step]:
        """Connect, Reset, Tear down. Needed, but not part of the pitch."""
        return [s for s in self.steps if s.id in CHORE_IDS]


# ── markdown ─────────────────────────────────────────────────────────────────
# Small renderer for what the notebooks actually use: headings, bold, italic,
# inline code, links, bullet lists, tables, blockquotes, fenced code, and raw
# HTML (the inline SVG diagrams) passed straight through.
_INLINE_CODE = re.compile(r"`([^`]+)`")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![*\w])\*([^*\n]+)\*(?![*\w])")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BARE_URL = re.compile(r"(?<![\"'=>])(https?://[^\s<>)\]]+)")


def _inline(text: str) -> str:
    out = html.escape(text, quote=False)
    # Code first, so nothing inside a span of code gets bold or link treatment.
    holes: list[str] = []

    def stash(m):
        holes.append(f"<code>{m.group(1)}</code>")
        return f"\x00{len(holes) - 1}\x00"

    out = _INLINE_CODE.sub(stash, out)
    out = _LINK.sub(r'<a href="\2" target="_blank" rel="noreferrer">\1</a>', out)
    out = _BARE_URL.sub(r'<a href="\1" target="_blank" rel="noreferrer">\1</a>', out)
    out = _BOLD.sub(r"<strong>\1</strong>", out)
    out = _ITALIC.sub(r"<em>\1</em>", out)
    for i, hole in enumerate(holes):
        out = out.replace(f"\x00{i}\x00", hole)
    return out


def _table(rows: list[str]) -> str:
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    if len(cells) >= 2 and all(set(c) <= set("-: ") for c in cells[1]):
        head, body = cells[0], cells[2:]
    else:
        head, body = [], cells
    out = ['<table class="nb-table">']
    if head:
        out.append("<thead><tr>" + "".join(f"<th>{_inline(c)}</th>" for c in head) + "</tr></thead>")
    out.append("<tbody>")
    for row in body:
        out.append("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in row) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def render_markdown(src: str) -> str:
    lines = src.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if not stripped:
            i += 1
            continue

        # Fenced code
        if stripped.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            out.append('<pre class="nb-pre"><code>' + html.escape("\n".join(buf)) + "</code></pre>")
            continue

        # Raw HTML block (the inline SVG diagrams)
        if stripped.startswith("<"):
            buf = [line]
            i += 1
            while i < len(lines) and lines[i].strip():
                buf.append(lines[i])
                i += 1
            out.append('<div class="nb-figure">' + "\n".join(buf) + "</div>")
            continue

        # Table
        if stripped.startswith("|"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                buf.append(lines[i])
                i += 1
            out.append(_table(buf))
            continue

        # Blockquote
        if stripped.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip().lstrip(">").strip())
                i += 1
            out.append('<blockquote class="nb-quote">' + _inline(" ".join(buf)) + "</blockquote>")
            continue

        # Bullet list
        if re.match(r"^\s*[-*]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\s*[-*]\s+", lines[i]):
                items.append(re.sub(r"^\s*[-*]\s+", "", lines[i]))
                i += 1
            out.append("<ul>" + "".join(f"<li>{_inline(t)}</li>" for t in items) + "</ul>")
            continue

        # Numbered list
        if re.match(r"^\s*\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\s*\d+\.\s+", lines[i]):
                items.append(re.sub(r"^\s*\d+\.\s+", "", lines[i]))
                i += 1
            out.append("<ol>" + "".join(f"<li>{_inline(t)}</li>" for t in items) + "</ol>")
            continue

        # Heading
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = min(len(m.group(1)) + 1, 6)   # page already owns h1/h2
            out.append(f"<h{level}>{_inline(m.group(2))}</h{level}>")
            i += 1
            continue

        # Paragraph
        buf = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(
            r"^\s*([-*]\s|\d+\.\s|#{1,6}\s|\||>|```|<)", lines[i]
        ):
            buf.append(lines[i])
            i += 1
        out.append("<p>" + _inline(" ".join(s.strip() for s in buf)) + "</p>")

    return "\n".join(out)


# ── parsing ──────────────────────────────────────────────────────────────────
def _heading(src: str) -> str | None:
    """The `##` heading that starts a step, ignoring anything inside a fence."""
    fenced = False
    for line in src.split("\n"):
        if line.strip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = re.match(r"^##\s+(?!#)(.*)$", line.strip())
        if m:
            return m.group(1).strip()
    return None


def _split_heading(title: str) -> tuple[str, str]:
    """`1.4 · Give the service one hostname` -> ('1.4', 'Give the service...')."""
    m = re.match(r"^(\d+[a-z]?(?:\.\d+)*)\s*[·:.\-]\s*(.*)$", title)
    if m:
        return m.group(1), m.group(2).strip()
    return "", title


def _intro_only(src: str) -> str:
    """The notebook's opening cell, minus the bits that only mean something in
    Jupyter: its own h1 (the page has one) and the kernel blockquote."""
    keep = []
    for line in src.split("\n"):
        stripped = line.strip()
        if stripped.startswith("# ") or stripped.startswith(">"):
            continue
        keep.append(line)
    return "\n".join(keep)


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:48] or "step"


def _blurb(blocks: list[Block]) -> str:
    """One line for the card. The notebooks lead with 'What we're doing:'."""
    for b in blocks:
        if b.kind != "md":
            continue
        # Diagrams carry a lot of label text that reads as nonsense in a card.
        source = re.sub(r"<svg\b.*?</svg>", " ", b.html, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", source)
        text = html.unescape(re.sub(r"\s+", " ", text)).strip()
        text = re.sub(r"\s+([,.;:)])", r"\1", text).replace("( ", "(")
        m = re.search(r"What we(?:'|’)re doing:\s*(.+?)(?:\s*(?:How|What you(?:'|’)ll see):|$)", text)
        if m:
            lead = m.group(1).strip().rstrip(".")
            return _first_sentences(lead[:1].upper() + lead[1:] + ".")
        if text:
            return _first_sentences(text)
    return ""


def _first_sentences(text: str, limit: int = 170) -> str:
    """Whole sentences up to the limit, so a card never ends mid-clause."""
    out = ""
    for part in re.split(r"(?<=[.!?])\s+", text):
        if out and len(out) + 1 + len(part) > limit:
            break
        out = f"{out} {part}".strip()
    if not out:
        out = text[:limit].rsplit(" ", 1)[0] + "…"
    # Never leave a card hanging on an opened bracket.
    while out.count("(") > out.count(")"):
        out = out[:out.rfind("(")].strip().rstrip(",;:")
    return out


def load(demo_id: str) -> Demo:
    meta = DEMOS[demo_id]
    nb = json.loads((NOTEBOOKS / meta["notebook"]).read_text())

    intro: list[str] = []
    steps: list[Step] = []
    current: Step | None = None
    seen: set[str] = set()
    fired: set[int] = set()
    dropping = False

    for cell in nb.get("cells", []):
        src = "".join(cell.get("source", []))
        if not src.strip():
            continue
        if dropping and not (cell.get("cell_type") == "markdown" and _heading(src)):
            continue

        if cell.get("cell_type") == "markdown":
            src = _present(src, demo_id, fired)
            if not src.strip():
                continue
            head = _heading(src)
            if head:
                num, title = _split_heading(head)
                sid = num or _slug(title.split("\u00b7")[0])
                while sid in seen:
                    sid += "-x"
                seen.add(sid)
                # Drop the heading line itself; the page renders it as the title.
                body = "\n".join(
                    l for l in src.split("\n") if l.strip() != f"## {head}"
                )
                if sid in meta.get("drop", []):
                    # Skip the whole section, not just its heading: with
                    # current unset, its prose would otherwise land in the intro.
                    current, dropping = None, True
                    continue
                dropping = False
                current = Step(id=sid, num=num, title=title, blurb="")
                if body.strip():
                    current.blocks.append(Block("md", html=render_markdown(body)))
                steps.append(current)
                continue
            if current is None:
                intro.append(render_markdown(_intro_only(src)))
            else:
                current.blocks.append(Block("md", html=render_markdown(src)))
        elif cell.get("cell_type") == "raw":
            # A raw cell is a snippet to paste somewhere, never something to run.
            if current is not None:
                current.blocks.append(Block("md", html=render_markdown("```\n" + src.rstrip("\n") + "\n```")))
        else:
            if current is None:
                continue
            current.blocks.append(Block("code", source=src.rstrip("\n")))

    for s in steps:
        s.blurb = _blurb(s.blocks)

    return Demo(
        id=demo_id,
        kicker=meta["kicker"],
        title=meta["title"],
        blurb=meta["blurb"],
        clusters=meta["clusters"],
        intro_html="\n".join(intro),
        steps=steps,
        rules_fired=fired,
    )


# ── running ──────────────────────────────────────────────────────────────────
_procs: dict[str, subprocess.Popen] = {}
_procs_lock = threading.Lock()
_execution_lock = threading.Lock()


def run(demo_id: str, step_id: str, index: int, emit, *, part: int | None = None, revision: str = "",
        params: dict | None = None) -> None:
    """Run one code block, streaming {type: out|done|error} events."""
    demo = load(demo_id)
    step = demo.step(step_id)
    if step is None:
        return emit({"type": "error", "text": f"no step {step_id}"})
    code = [b for b in step.blocks if b.kind == "code"]
    if index < 0 or index >= len(code):
        return emit({"type": "error", "text": f"no block {index} in {step_id}"})

    key = f"{demo_id}/{step_id}/{index}"
    source = code[index].source
    if part is not None:
        import present
        try:
            source = present.action_script(demo, step, index, part, revision, params)
        except present.ParamError as e:
            return emit({"type": "error", "text": str(e)})
    script = preamble(demo_id) + "\n" + source
    execute(key, script, emit, step.label)


def execute(key: str, script: str, emit, label: str) -> None:
    """One cluster-changing operation at a time, including resets and other tabs."""
    # Try a cross-process file lock first so separate processes (CLI, verify_labs)
    # cannot run concurrently. If it is already held, return a helpful error.
    try:
        lock_ctx = file_lock(blocking=False)
        lock = lock_ctx.__enter__()
    except BlockingIOError:
        return emit({"type": "error", "text": "Another lab command or reset is running in another process. Wait for it to finish."})
    except Exception as e:
        # If locking fails for unexpected reasons, fall back to in-process guard but warn.
        emit({"type": "out", "text": f"Warning: file lock unavailable: {e}. Proceeding with in-process guard."})
        lock = None

    if not _execution_lock.acquire(blocking=False):
        if lock is not None:
            try:
                lock_ctx.__exit__(None, None, None)
            except Exception:
                pass
        return emit({"type": "error", "text": "Another lab command or reset is running. Wait for it to finish."})
    proc = None
    try:
        emit({"type": "start", "step": label})
        proc = subprocess.Popen(
            ["bash", "-c", script], cwd=str(NOTEBOOKS),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env={**os.environ, "TERM": "dumb"}, start_new_session=True,
        )
        with _procs_lock:
            _procs[key] = proc
        for raw in proc.stdout:
            emit({"type": "out", "text": raw.decode("utf-8", "replace").rstrip("\n")})
        proc.wait()
        emit({"type": "done", "code": proc.returncode})
    finally:
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, 15)
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, 9)
                proc.wait()
            except ProcessLookupError:
                pass
        with _procs_lock:
            _procs.pop(key, None)
        if proc and proc.stdout:
            proc.stdout.close()
        _execution_lock.release()
        if lock is not None:
            try:
                lock_ctx.__exit__(None, None, None)
            except Exception:
                pass


def stop(demo_id: str, step_id: str, index: int) -> dict:
    key = f"{demo_id}/{step_id}/{index}"
    with _procs_lock:
        proc = _procs.get(key)
    if proc is None:
        return {"stopped": False, "why": "not running"}
    try:
        os.killpg(os.getpgid(proc.pid), 15)
    except (ProcessLookupError, PermissionError) as e:
        return {"stopped": False, "why": str(e)}
    return {"stopped": True}


# ── pages ────────────────────────────────────────────────────────────────────
BRAND_SVG = """<svg width="22" height="22" viewBox="0 0 48 48" aria-hidden="true">
      <g stroke="#a78bfa" stroke-width="2.4" opacity="0.6" stroke-linecap="round">
        <line x1="24" y1="7" x2="7" y2="24"/><line x1="24" y1="7" x2="41" y2="24"/>
        <line x1="7" y1="24" x2="41" y2="24"/><line x1="7" y1="24" x2="24" y2="41"/>
        <line x1="41" y1="24" x2="24" y2="41"/>
      </g>
      <circle cx="24" cy="7" r="5" fill="#a78bfa"/>
      <circle cx="7" cy="24" r="5" fill="#7c3aed"/>
      <circle cx="41" cy="24" r="5" fill="#7c3aed"/>
      <circle cx="24" cy="41" r="5" fill="#5b21b6"/>
    </svg>"""


NAV_GROUPS = [("connectivity", "Connectivity"), ("agentic", "Agentic")]


def nav_menus(active: str) -> str:
    """One dropdown per area instead of a link per lab, so the bar stays the same
    width however many labs there are. Built from the catalogue, so a new lab
    lands in its area's menu. The menu holding the current page shows its name."""
    entries = [(s["href"], s["title"], s["kicker"], s["domain"]) for s in STORIES]
    entries += [(f"/{d}", m["short"], m["kicker"], m["domain"]) for d, m in DEMOS.items()]
    out = ['<a href="/"%s>All labs</a>' % (' class="active"' if active in ("", "/") else "")]
    for key, label in NAV_GROUPS:
        items = [e for e in entries if e[3] == key]
        current = next((e for e in items if e[0] == active), None)
        rows = "".join(
            f'<a href="{href}" role="menuitem"{" aria-current=\"page\"" if href == active else ""}>'
            f'<b>{html.escape(title)}</b><small>{html.escape(kicker.split(" · ")[0])}</small></a>'
            for href, title, kicker, _ in items)
        summary = html.escape(label) + (f' <span class="nav-current">· {html.escape(current[1])}</span>' if current else "")
        out.append(f'<details class="nav-menu{" active" if current else ""}"><summary>{summary}</summary>'
                   f'<div class="nav-menu-list" role="menu">{rows}</div></details>')
    return "".join(out)


def shell(title: str, body: str, active: str = "", extra_head: str = "", scripts: str = "",
          body_class: str = "") -> str:
    def link(href: str, label: str) -> str:
        cls = ' class="active"' if href == active else ""
        return f'<a href="{href}"{cls}>{label}</a>'

    nav = nav_menus(active)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} · Solo.io</title>
  <link rel="icon" type="image/svg+xml" href="/static/favicon.svg">
  <link rel="icon" type="image/png" href="/static/favicon.png">
  <link rel="stylesheet" href="/static/css/app.css">
{extra_head}</head>
<body{f' class="{body_class}"' if body_class else ''}>
<nav class="console-nav">
  <a class="brand" href="/">{BRAND_SVG}
    Solo.io
  </a>
  <div class="nav-links">{nav}</div>
  <span class="nav-status"><i class="dot" id="dot"></i><span id="status-label"></span></span>
</nav>
{body}
<script src="/static/js/status.js"></script>
<script src="/static/js/nav.js"></script>
{scripts}
</body>
</html>
"""


def _one_runner(demo: Demo, step: Step, index: int) -> str:
    """The Run widget for one code block: the bash, Copy, Run, Stop, output."""
    code = [b for b in step.blocks if b.kind == "code"]
    label = f"command {index + 1}" if len(code) > 1 else "command"
    return f"""<div class="nb-run" data-demo="{html.escape(demo.id)}" data-step="{html.escape(step.id)}" data-index="{index}">
  <div class="nb-run-head">
    <span class="nb-run-label">{label}</span>
    <div class="btns">
      <button class="btn nb-copy" type="button">Copy</button>
      <button class="btn primary nb-go" type="button">▶ Run</button>
      <button class="btn nb-stop" type="button" disabled>Stop</button>
    </div>
  </div>
  <pre class="nb-code"><code>{html.escape(code[index].source)}</code></pre>
  <pre class="log nb-out" hidden></pre>
</div>"""


def runner(demo: Demo, step: Step) -> str:
    return "\n".join(_one_runner(demo, step, i) for i in range(step.code_blocks))


def console_buttons(demo: Demo) -> str:
    return "".join(
        f'<button class="btn{" primary" if i == 0 else ""} nb-console" type="button" '
        f'data-demo="{html.escape(demo.id)}" data-console="{html.escape(c["id"])}" '
        f'title="{html.escape(c.get("note", ""))}">{html.escape(c["label"])}</button>'
        for i, c in enumerate(consoles(demo.id))
    )


def demo_page(demo: Demo) -> str:
    import present
    guide = present.spec(demo.id) or {}
    cards = []
    for n, s in enumerate(demo.story, 1):
        st = guide.get("steps", {}).get(s.id, {})
        cards.append(f"""    <a class="feature-card" href="/{demo.id}/{html.escape(s.id)}">
      <div class="kicker">Chapter {n}</div>
      <h2>{html.escape(st.get('title', s.title))}</h2>
      <p>{html.escape(st.get('say', s.blurb))}</p>
      <span class="go">Open chapter →</span>
    </a>""")

    clusters = " and ".join(f"<code>{html.escape(c)}</code>" for c in demo.clusters)
    buttons = console_buttons(demo)
    import present
    if present.spec(demo.id) and demo.story:
        first = demo.story[0]
        buttons = (f'<a class="btn primary" href="/{demo.id}/{html.escape(first.id)}">'
                    f'Start lab</a>'
                   + buttons.replace(" primary nb-console", " nb-console"))
    import lab_reset
    chores = lab_reset.control(demo.id)
    body = f"""
<header class="hero">
  <div class="wrap">
    <div class="crumb"><a href="/">← All labs</a></div>
    <div class="eyebrow">{html.escape(demo.kicker)}</div>
    <h1>{html.escape(demo.title)}</h1>
    <p>{html.escape(demo.blurb)}</p>
    <div class="btns">{buttons}</div>
    <p class="console-msg" id="console-msg"></p>
  </div>
</header>

<div class="wrap">
  <div class="panel nb-intro">
    <details class="rig">
      <summary>Environment and reset</summary>
      <p class="rig-note">Reset removes lab resources so you can start again.</p>
      <p class="rig-note">{DEMOS[demo.id].get("needs", "")}</p>
{chores}
    </details>
    <p class="sub nb-lede">Runs against {clusters}. Follow the chapters in order. Run each numbered step,
    check its result, then continue. <b>Run all steps</b> runs the current chapter and stops if a check fails.</p>
    <p>{html.escape(guide.get('intro', ''))}</p>
  </div>

  <div class="feature-grid">
{chr(10).join(cards)}
  </div>
</div>
"""
    import terminal
    return shell(demo.title, body + terminal.dock(demo.id), active=f"/{demo.id}", extra_head=terminal.HEAD,
                 scripts='<script src="/static/js/notebook.js"></script><script src="/static/js/lab-reset.js"></script>'
                 + terminal.SCRIPTS)


def step_page(demo: Demo, step: Step) -> str:
    # Page across the story. A chore is reachable by link but is not in the flow.
    order = demo.story if step.num else demo.steps
    idx = order.index(step) if step in order else -1
    prev_s = order[idx - 1] if idx > 0 else None
    next_s = order[idx + 1] if 0 <= idx < len(order) - 1 else None

    parts = []
    code_i = 0
    for b in step.blocks:
        if b.kind == "md":
            parts.append(f'<div class="nb-md">{b.html}</div>')
            continue
        parts.append(_one_runner(demo, step, code_i))
        code_i += 1

    if not step.code_blocks:
        parts.append('<p class="nb-note">Nothing to run here. This one is read and point at a screen.</p>')

    nav = []
    if prev_s:
        nav.append(f'<a class="btn" href="/{demo.id}/{html.escape(prev_s.id)}">← {html.escape(prev_s.label)}</a>')
    else:
        nav.append("<span></span>")
    if next_s:
        nav.append(f'<a class="btn primary" href="/{demo.id}/{html.escape(next_s.id)}">{html.escape(next_s.label)} →</a>')
    pager = f'<div class="nb-pager">{"".join(nav)}</div>'

    body = f"""
<header class="hero">
  <div class="wrap">
    <div class="crumb"><a href="/{demo.id}">← {html.escape(demo.title)}</a></div>
    <div class="eyebrow">{html.escape(demo.kicker.split(' · ')[0])}{' · STEP ' + html.escape(step.num) if step.num else ''}</div>
    <h1>{html.escape(step.title)}</h1>
    <p>{html.escape(step.blurb)}</p>
    <div class="btns">{console_buttons(demo)}</div>
    <p class="console-msg" id="console-msg"></p>
  </div>
</header>

<div class="wrap">
  {pager}
  <div class="panel nb-step">
{chr(10).join(parts)}
  </div>
  {pager}
</div>
"""
    return shell(f"{step.label}", body, active=f"/{demo.id}",
                 scripts='<script src="/static/js/notebook.js"></script>')


# The top-level catalogue. The hand-built console pages are one entry; every
# notebook demo is another.
STORIES = [
    {
        "href": "/user-story-1",
        "domain": "agentic",
        "kicker": "AGENTICS",
        "title": "Agentics Overview",
        "blurb": "Explore desktop enrolment, model routing, MCP token usage, cost controls, agent approvals and substrate.",
        "bullets": [
            "01 Enrol · 02 and 03 Path and routing",
            "04 Economics · 05 Cost",
            "06 No-code and approval · 07 Substrate",
        ],
        "go": "Open Agentics Overview",
    },
    {
        "href": "/kernwerk",
        "domain": "agentic",
        "kicker": "DATA CLASSIFICATION",
        "title": "Data that must not leave",
        "blurb": "Three classes of data and a policy that lives in four people's heads. "
                 "Enrol the laptop, let the gateway pick where each question may go, "
                 "then watch personal data removed before it reaches an outside model.",
        "bullets": [
            "01 Enrol · Agentdesktop",
            "02 Routing · Gateway decisions with Claude Code",
            "03 Data protection · DLP and guardrails",
        ],
        "go": "Open data classification",
    },
]


def _lab_product(kicker: str) -> str:
    first = kicker.split("·")[0].strip().lower()
    for name in ("agentregistry", "agentgateway", "kagent", "istio"):
        if name in first:
            return name
    return "agentgateway"


def _first_sentence(text: str) -> str:
    m = re.match(r"(.+?[.!?])(\s|$)", text.strip())
    return m.group(1) if m else text.strip()


def home_page() -> str:
    labs = []
    for demo_id, meta in DEMOS.items():
        steps = [s for s in load(demo_id).steps if s.num]
        product = _lab_product(meta["kicker"])
        glyph = {"agentregistry": "AR", "agentgateway": "AG", "kagent": "KA", "istio": "IS"}[product]
        labs.append(f"""      <a class="st-lab" href="/{demo_id}" data-domain="{meta['domain']}" data-lab="{demo_id}">
        <div class="st-lab-top"><span class="st-glyph {product}">{glyph}</span>
          <div><small>{html.escape(meta['kicker'])}</small></div></div>
        <h3>{html.escape(meta['title'])}</h3>
        <p>{html.escape(_first_sentence(meta['blurb']))}</p>
        <div class="st-lab-foot"><span class="steps">{len(steps)} steps</span><span class="st-pill" data-ready>checking…</span></div>
      </a>""")

    body = f"""
<header class="st-hero">
  <div class="st-wrap">
    <div class="st-eyebrow">Solo.io · live demos</div>
    <h1>Agents, gateways and mesh, <em>running live</em> on this laptop.</h1>
    <p class="lead">Every page runs real commands against real clusters. Follow a story from start to finish, or open a single lab.</p>
    <div class="st-live" id="live">
      <div class="st-stat"><span>Clusters</span><div class="st-dots" id="live-clusters"><i class="st-skel"></i></div><small>Checked just now</small></div>
      <div class="st-stat"><b id="live-agents"><i class="st-skel"></i></b><span>Agents deployed on kagent</span></div>
      <div class="st-stat"><b id="live-mcp"><i class="st-skel"></i></b><span id="live-mcp-sub">MCP servers in AgentRegistry</span></div>
      <div class="st-stat"><b>{len(DEMOS) + len(STORIES)}</b><span>Stories and labs</span></div>
    </div>
  </div>
</header>

<section class="st-section">
  <div class="st-wrap">
    <div class="st-head"><div><div class="st-eyebrow">Follow a story</div><h2>Start here</h2></div></div>
    <div class="st-stories">
      <a class="st-story" href="/user-story-1">
        <div class="st-eyebrow">Agentics overview · 7 steps</div>
        <h3>From an enrolled laptop to agents that sleep between turns</h3>
        <p>Enrol a Mac, watch the gateway pick a model per question, cut token spend, build an agent with no code and let a platform admin decide what it may touch.</p>
        <div class="st-track">
          <span><b>01</b>Enrol</span><span><b>02</b>Path</span><span><b>03</b>Routing</span><span><b>04</b>Tokens</span>
          <span><b>05</b>Cost</span><span><b>06</b>Agents</span><span><b>07</b>Substrate</span>
        </div>
        <span class="st-go">Open the overview <i>→</i></span>
      </a>
      <a class="st-story" href="/kernwerk">
        <div class="st-eyebrow">Data classification · 3 steps</div>
        <h3>Data that must not leave</h3>
        <p>Three classes of data and a gateway that routes each question live, with personal data replaced before anything reaches an outside model.</p>
        <div class="st-flow">
          <div><span class="src">Class 1 · public post</span><span class="arrow">→</span><span class="dst out">Can go anywhere</span></div>
          <div><span class="src">Class 2 · works council</span><span class="arrow">→</span><span class="dst out">Must stay in the EU</span></div>
          <div><span class="src">Class 3 · finance review</span><span class="arrow">→</span><span class="dst keep">Never leaves Kernwerk</span></div>
          <div><span class="src">Personal data in any prompt</span><span class="arrow">→</span><span class="dst strip">Replaced first</span></div>
        </div>
        <span class="st-go">Open data classification <i>→</i></span>
      </a>
    </div>
  </div>
</section>

<section class="st-section">
  <div class="st-wrap">
    <div class="st-head">
      <div><div class="st-eyebrow">Or open a lab</div><h2>Single labs</h2></div>
      <div class="st-chips" id="cat-filter" role="group" aria-label="Filter by area">
        <button type="button" data-filter="all" aria-pressed="true">All <b></b></button>
        <button type="button" data-filter="agentic" aria-pressed="false">Agentic <b></b></button>
        <button type="button" data-filter="connectivity" aria-pressed="false">Connectivity <b></b></button>
      </div>
    </div>
    <div class="st-labs" id="catalogue">
{chr(10).join(labs)}
    </div>
  </div>
</section>
<div style="height:70px"></div>
"""
    return shell("Solo.io Agentics & Connectivity Live Demos", body,
                 extra_head='  <link rel="stylesheet" href="/static/css/stage.css">\n',
                 scripts='<script src="/static/js/home.js"></script>', body_class="stage")


# ── consoles ─────────────────────────────────────────────────────────────────
# The demo is watched in the Gloo UI and the Cost Management UI. Neither has an
# ingress, so both need a port-forward. The page asks for one by name and gets a
# URL back, which is the same thing consoles.sh does from a terminal.
def consoles(demo_id: str) -> list[dict]:
    return DEMOS.get(demo_id, {}).get("consoles", [])


def _listening(port: int) -> bool:
    import socket
    with socket.socket() as sock:
        sock.settimeout(0.4)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def open_console(demo_id: str, console_id: str) -> dict:
    cfg = next((c for c in consoles(demo_id) if c["id"] == console_id), None)
    if cfg is None:
        return {"ok": False, "error": "unknown console"}
    if cfg.get("ingress"):
        lb = subprocess.run(
            ["kubectl", "--context", cfg["context"], "-n", cfg["namespace"], "get", "gateway", cfg["gateway"],
             "-o", "jsonpath={.status.addresses[0].value}"], capture_output=True, text=True).stdout.strip()
        if not lb:
            return {"ok": False, "error": f"{cfg['gateway']} has no address"}
        return {"ok": True, "url": f"http://{cfg['ingress']}.{lb}.sslip.io/"}
    if _listening(cfg["local"]):
        return {"ok": True, "url": cfg["url"]}

    present = subprocess.run(
        ["kubectl", "--context", cfg["context"], "-n", cfg["namespace"],
         "get", "svc", cfg["service"], "-o", "name"],
        capture_output=True, text=True,
    )
    if present.returncode != 0:
        why = present.stderr.strip().split("\n")[-1][:160]
        return {"ok": False, "error": why or f"{cfg['service']} is not installed"}

    subprocess.Popen(
        ["kubectl", "--context", cfg["context"], "-n", cfg["namespace"],
         "port-forward", f"svc/{cfg['service']}", f"{cfg['local']}:{cfg['remote']}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    for _ in range(30):
        if _listening(cfg["local"]):
            return {"ok": True, "url": cfg["url"]}
        __import__("time").sleep(0.5)
    return {"ok": False, "error": "port-forward did not come up"}
