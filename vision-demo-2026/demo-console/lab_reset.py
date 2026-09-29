"""Scoped lab resets. The installed platform and other console stories stay up."""
from __future__ import annotations

import html
import os
import shlex
import uuid

import notebooks

GENERATIONS = {lab: uuid.uuid4().hex for lab in notebooks.DEMOS}
SCOPES = {
    "demo-13": "Removes the lab's kagent Agent, MCPServer and gateway namespaces, its dedicated rate-limiter Service and local test identity and task files. Also removes dd-models from the earlier simulator version. Shared controllers and other labs stay up.",
    "demo-1": "Removes Bookinfo from both clusters and the lab's east-west peering gateways.",
    "demo-2": "Removes petshop and warehouse and turns workload claims off. Petshop is shared with the Waypoint policies lab, so its progress is also cleared.",
    "demo-3": "Removes petshop, including its waypoint and policies. Petshop is shared with the Ambient L4 identity lab, so its progress is also cleared.",
    "demo-7": "Removes this lab's model and MCP routes, policies, keys and budgets. Restores the model simulators and clears gateway eviction state.",
    "demo-4": "Removes the agentdemo agent, its MCP tool servers, any AccessPolicy, the local scaffold and the AgentCore runtime instance. Scales the AgentRegistry platform up first if it is parked. The approved catalogue stays.",
    "demo-6": "Puts pool-a back to cold (KV cache 10%, no queue) and pool-b to hot (90%, 8 waiting). The cluster, gateway and picker stay up.",
    "demo-12": "Deletes the lab's agent, harness and WorkerPool, and the conversation it was following. The default pool, other agents and Agent Substrate stay up.",
    "demo-11": "Removes the Petstore namespace, the rest-petstore and pet-workflow MCP backends, the upstream backend, both routes and the spec ConfigMap.",
    "all": "Resets every lab. The clusters, controllers, Keycloak and monitoring remain installed.",
}
MODEL_RESOURCES = {
    "httproute": ["models", "resilient", "service-models", "mcp"],
    "enterpriseagentgatewaypolicy": ["resilient-health", "models-jwt", "identity-metrics", "models-access", "models-ratelimit", "service-models-auth", "mcp-jwt"],
    "agentgatewaypolicy": ["extract-model", "mcp-tool-authz"],
    "enterpriseagentgatewaybackend": ["azure-gpt5", "bedrock-haiku", "anthropic-claude", "resilient-models", "mcp-hub"],
    "enterpriseagentgatewaybudget": ["service-budgets"],
    "ratelimitconfig": ["per-user-tokens"],
    "secret": ["team-data-platform-keys"],
}


def affected(lab: str) -> list[str]:
    if lab == "all":
        return list(notebooks.DEMOS)
    if lab in ("demo-2", "demo-3"):
        return ["demo-2", "demo-3"]
    if lab not in notebooks.DEMOS:
        raise ValueError("Unknown lab")
    return [lab]


def reset_script(lab: str) -> str:
    affected(lab)  # validate before constructing any command
    c1 = os.environ.get("CLUSTER1", "kind-mesh1")
    c2 = os.environ.get("CLUSTER2", "kind-mesh2")
    ctx = os.environ.get("CTX", "kind-mesh1")
    ns = os.environ.get("NS", "agentgateway-system")
    lines = ["set -euo pipefail"]

    def cmd(*args):
        return shlex.join(args)

    def remove(context, kind, names, namespace=None):
        base = ["kubectl", "--context", context]
        if namespace:
            base += ["-n", namespace]
        lines.append(cmd(*base, "delete", kind, *names, "--ignore-not-found", "--wait=true", "--timeout=180s"))
        # Read state back. A successful delete request alone is not a reset.
        lines.append(f'left=$({cmd(*base, "get", kind, *names, "--ignore-not-found", "-o", "name")})')
        lines.append('[ -z "$left" ] || { printf "Still present: %s\\n" "$left"; exit 1; }')

    if lab in ("demo-13", "all"):
        remove("kind-mesh1", "namespace", ["dd-agents", "dd-models", "dd-tools", "dd-gateway"])
        remove("kind-mesh1", "service", ["dd-rate-limiter"], "agentgateway-system")
        lines.append('rm -f "${TMPDIR:-/tmp}/defence-lab/private.pem" "${TMPDIR:-/tmp}/defence-lab/07-caller-identity.json" "${TMPDIR:-/tmp}/defence-lab/last-agent-task.json"')

    if lab in ("demo-1", "all"):
        # Remove both publishers before checking generated ServiceEntries.
        # While either Service still exists, the other istiod recreates its entry.
        for context in (c1, c2):
            remove(context, "namespace", ["bookinfo"])
        for context, peer in ((c1, c2.removeprefix("kind-")), (c2, c1.removeprefix("kind-"))):
            remove(context, "gateway", ["istio-eastwest", f"istio-remote-peer-{peer}"], "istio-eastwest")
        for context in (c1, c2):
            remove(context, "serviceentry", ["autogen.bookinfo.reviews"], "istio-system")
    if lab in ("demo-2", "demo-3", "all"):
        remove(ctx, "namespace", ["petshop"])
    if lab in ("demo-2", "all"):
        remove(ctx, "namespace", ["warehouse"])
        k = cmd("kubectl", "--context", ctx, "-n", "istio-system")
        h = cmd("helm", "--kube-context", ctx)
        claim = "{.spec.template.spec.containers[0].env[?(@.name=='ENABLE_WORKLOAD_CLAIMS')].value}"
        lines += [
            f"claims=$({k} get ds ztunnel -o {shlex.quote('jsonpath=' + claim)})",
            'if [ "$claims" = true ]; then',
            f"  version=$({h} list -n istio-system --filter '^ztunnel$' -o json | jq -er '.[0].chart | sub(\"^ztunnel-\"; \"\")')",
            f'  {h} upgrade ztunnel oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel -n istio-system --version "$version" --reuse-values --set-string env.ENABLE_WORKLOAD_CLAIMS=false --wait --timeout 5m',
            f"  {k} rollout status ds/ztunnel --timeout=180s",
            "fi",
            f"claims=$({k} get ds ztunnel -o {shlex.quote('jsonpath=' + claim)})",
            '[ "$claims" != true ] || { printf "Workload claims are still enabled\\n"; exit 1; }',
        ]
    if lab in ("demo-7", "all"):
        for kind, names in MODEL_RESOURCES.items():
            remove(ctx, kind, names, ns)
        # Budget-generated configs are controller-owned. Wait for their removal.
        k = cmd("kubectl", "--context", ctx, "-n", ns)
        lines += [
            f"for attempt in $(seq 1 30); do",
            f"  remaining=$({k} get ratelimitconfig -o name | grep '/agw-budget-service-budgets' || true)",
            '  [ -z "$remaining" ] && break',
            "  sleep 2",
            "done",
            '[ -z "$remaining" ] || { printf "Budget rate limit config still present\\n"; exit 1; }',
        ]
        for model in ("azure-openai", "bedrock"):
            lines.append(cmd("kubectl", "--context", ctx, "-n", "ai-models", "scale", f"deploy/{model}", "--replicas=1"))
            lines.append(cmd("kubectl", "--context", ctx, "-n", "ai-models", "rollout", "status", f"deploy/{model}", "--timeout=120s"))
        lines += [f"{k} rollout restart deploy/ai-gateway", f"{k} rollout status deploy/ai-gateway --timeout=180s"]
    if lab in ("demo-4", "all"):
        k = cmd("kubectl", "--context", ctx)
        # The platform is parked at zero replicas between demos. reset.sh purges the
        # catalogue through arctl, so the registry and IdP must be serving first.
        lines += [
            "for ns in agentregistry-system ar-keycloak kagent kyverno; do",
            f"  for r in $({k} -n \"$ns\" get deploy,statefulset -o {shlex.quote('jsonpath={range .items[?(@.spec.replicas==0)]}{.kind}/{.metadata.name} {end}')}); do",
            f"    {k} -n \"$ns\" scale \"$r\" --replicas=1",
            "  done",
            "done",
            f"{k} -n ar-keycloak rollout status statefulset/keycloak --timeout=300s",
            f"{k} -n agentregistry-system rollout status deploy/agentregistry-enterprise-server --timeout=300s",
            f"{k} -n kagent rollout status deploy/kagent-controller --timeout=300s",
            'rm -f "${TMPDIR:-/tmp}"/agentcore-deploy.log*',
            "(cd demo-scripts/agentregistry && bash scripts/reset.sh)",
        ]
        remove(ctx, "agent", ["agentdemo"], "kagent")
        remove(ctx, "mcpserver", ["my-mcp", "everything-server"], "kagent")
        remove(ctx, "accesspolicy", ["allow-sum-only"], "kagent")
        lines.append('[ ! -e agents/agentdemo ] && [ ! -e agents/dice-game ] || { printf "Scaffold still present\\n"; exit 1; }')
    if lab in ("demo-6", "all"):
        k = cmd("kubectl", "--context", "kind-inference", "-n", "inference")
        lines += [
            "export CTX=kind-inference NS=inference",
            ". demo-scripts/scripts/inference-helpers.sh",
            "set_metrics a 0.10 0 1",
            "set_metrics b 0.90 8 5",
        ]
        # Read the pinned gauges back rather than trusting the apply.
        for r, kv, q in (("a", "0.10", "0"), ("b", "0.90", "8")):
            lines += [
                f"cfg=$({k} get cm sim-pool-{r} -o jsonpath='{{.data.config\\.yaml}}')",
                f'echo "$cfg" | grep -q "kv-cache-usage: {kv}" && echo "$cfg" | grep -q "waiting-requests: {q}$" '
                f'|| {{ printf "Still present: pool-{r} gauges not restored\\n"; exit 1; }}',
            ]
    if lab in ("demo-12", "all"):
        sub = "kind-substrate"
        remove(sub, "sandboxagent", ["lab-agent"], "kagent")
        remove(sub, "agentharness", ["lab-harness"], "kagent")
        remove(sub, "workerpool", ["lab-pool"], "kagent")
        # The rendered ActorTemplates are owned by the agent and the harness; read them back.
        lines += [
            f"left=$({cmd('kubectl', '--context', sub, '-n', 'kagent', 'get', 'actortemplate', '-o', 'name')} | grep -E '/lab-(agent|harness)' || true)",
            '[ -z "$left" ] || { printf "Still present: %s\\n" "$left"; exit 1; }',
            'rm -f "${TMPDIR:-/tmp}/substrate-lab.session"',
        ]
    if lab in ("demo-11", "all"):
        remove(ctx, "httproute", ["rest-petstore", "pet-workflow"], ns)
        remove(ctx, "enterpriseagentgatewaybackend", ["pet-workflow", "rest-petstore", "petstore-upstream"], ns)
        remove(ctx, "configmap", ["rest-petstore-openapi"], ns)
        remove(ctx, "namespace", ["rest-api"])
    lines.append('printf "Reset verified\\n"')
    return "\n".join(lines)


def run(lab: str, emit):
    labs = affected(lab)
    script = reset_script(lab)

    def event(ev):
        if ev["type"] == "start":
            # Invalidate on start, including partial or failed resets.
            for name in labs:
                GENERATIONS[name] = uuid.uuid4().hex
        if ev["type"] == "done":
            ev = {**ev, "labs": labs, "generations": GENERATIONS}
        emit(ev)

    notebooks.execute("reset/" + lab, script, event, "Reset " + lab)


def control(lab: str) -> str:
    return f'''<section class="lab-reset" data-reset="{html.escape(lab)}">
      <h3>{'Reset all labs' if lab == 'all' else 'Reset lab'}</h3>
      <p>{html.escape(SCOPES[lab])}</p>
      <button class="btn lab-reset-go" type="button">{'Reset all labs' if lab == 'all' else 'Reset lab'}</button>
      <p class="lab-reset-status" role="status"></p><pre class="log lab-reset-output" hidden></pre>
    </section>'''


def admin_page() -> str:
    cards = ''.join(f'<div class="panel"><h2>{html.escape(meta["title"])}</h2>{control(lab)}</div>' for lab, meta in notebooks.DEMOS.items())
    return notebooks.shell("Lab administration", f'''<header class="hero"><div class="wrap"><h1>Lab administration</h1>
      <p>Reset the local lab resources and verify their removal.</p></div></header>
      <main class="wrap"><div class="panel">{control('all')}</div>{cards}</main>''',
      scripts='<script src="/static/js/lab-reset.js"></script>')
