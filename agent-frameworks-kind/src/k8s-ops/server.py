"""k8s-ops — a small MCP server exposing four read tools and one mutating tool
against the live Kubernetes API, scoped by RBAC to the `incident` namespace.

It sits behind agentgateway's /mcp route, so every tool call is subject to gateway
policy: tool curation, and the ext-auth HITL gate on the single mutating tool
(patch_deployment_image). All five SRE crews — the kagent-native declarative team
and the BYO ADK / LangChain / LangGraph / CrewAI / AutoGen crews — call these same
tools, so the comparison is apples-to-apples: only the framework wiring differs.

The MCP endpoint is served at /mcp (FastMCP streamable-http). /healthz is a plain
readiness probe. Pattern from agentic-hitl-kind/src/ops-tools/server.py.
"""
from __future__ import annotations

import contextlib
import os

from kubernetes import client, config
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

# FastMCP auto-enables DNS rebinding protection when its internal host defaults to
# 127.0.0.1, which then rejects the in-cluster gateway Host header with a 421. We
# sit behind agentgateway, so disable it.
_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)

# In-cluster by default; fall back to kubeconfig for local runs.
try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

_core = client.CoreV1Api()
_apps = client.AppsV1Api()

mcp = FastMCP("k8s-ops", stateless_http=True, transport_security=_TS)


@mcp.tool()
def get_pods(namespace: str = "incident") -> dict:
    """List pods in a namespace with phase, restart count, and the reason any
    container is not ready (for example ImagePullBackOff or CrashLoopBackOff)."""
    pods = _core.list_namespaced_pod(namespace).items
    out = []
    for p in pods:
        reasons = []
        restarts = 0
        for cs in p.status.container_statuses or []:
            restarts += cs.restart_count or 0
            st = cs.state
            if st and st.waiting and st.waiting.reason:
                reasons.append(st.waiting.reason)
            if st and st.terminated and st.terminated.reason:
                reasons.append(st.terminated.reason)
        out.append(
            {
                "name": p.metadata.name,
                "phase": p.status.phase,
                "restarts": restarts,
                "reasons": reasons,
            }
        )
    return {"namespace": namespace, "pods": out}


@mcp.tool()
def get_events(namespace: str = "incident") -> dict:
    """Recent events in a namespace, newest last. Surfaces image pull errors,
    failed scheduling, OOMKills, and other workload-level failures."""
    ev = _core.list_namespaced_event(namespace).items
    items = [
        {
            "type": e.type,
            "reason": e.reason,
            "object": f"{e.involved_object.kind}/{e.involved_object.name}",
            "message": e.message,
            "count": e.count,
        }
        for e in ev
    ]
    return {"namespace": namespace, "events": items[-40:]}


@mcp.tool()
def get_pod_logs(namespace: str, pod: str, tail_lines: int = 50) -> dict:
    """Tail a pod's logs. If the container never started (for example
    ImagePullBackOff) Kubernetes returns no logs; that absence is itself a signal."""
    try:
        logs = _core.read_namespaced_pod_log(
            name=pod, namespace=namespace, tail_lines=tail_lines
        )
    except client.ApiException as e:
        logs = f"(no logs available: {e.reason})"
    return {"namespace": namespace, "pod": pod, "logs": logs}


@mcp.tool()
def describe_deployment(namespace: str, name: str) -> dict:
    """Describe a Deployment: container images, replica readiness, and conditions."""
    d = _apps.read_namespaced_deployment(name=name, namespace=namespace)
    return {
        "namespace": namespace,
        "name": name,
        "containers": [
            {"name": c.name, "image": c.image} for c in d.spec.template.spec.containers
        ],
        "replicas": {
            "desired": d.spec.replicas,
            "ready": d.status.ready_replicas or 0,
            "available": d.status.available_replicas or 0,
        },
        "conditions": [
            {"type": c.type, "status": c.status, "reason": c.reason}
            for c in (d.status.conditions or [])
        ],
    }


@mcp.tool()
def patch_deployment_image(namespace: str, name: str, container: str, image: str) -> dict:
    """Set a container's image on a Deployment. This is the one mutating tool: the
    remediation. Behind the gateway it is the call the ext-auth HITL policy parks
    for a platform reviewer before it runs."""
    body = {
        "spec": {
            "template": {
                "spec": {"containers": [{"name": container, "image": image}]}
            }
        }
    }
    _apps.patch_namespaced_deployment(name=name, namespace=namespace, body=body)
    return {"patched": f"{namespace}/{name}", "container": container, "image": image}


async def health(_request):
    return JSONResponse({"status": "ok"})


# FastMCP's streamable-HTTP session manager must have its async context active
# before requests are handled; when mounted into a parent Starlette its own
# lifespan is not invoked, so thread it through here. The MCP endpoint lands at
# /mcp (the mount root + FastMCP's default streamable path).
@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


app = Starlette(
    routes=[
        Route("/healthz", health),
        Mount("/", app=mcp.streamable_http_app()),
    ],
    lifespan=lifespan,
)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        log_level=os.environ.get("LOG_LEVEL", "info"),
    )
