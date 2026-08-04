"""sre-tools — a small MCP server for a plausible SRE task.

Five tools over a mock cluster: three read-only, two that change things.

  read       list_pods, get_pod_logs, describe_deployment
  mutating   restart_deployment, scale_deployment

Unlike the two-endpoint split in agentic-hitl-kind, this server exposes ONE
MCP endpoint at /mcp with ONE tool set. That is deliberate. In this lab the
gating decision is not "which tools exist" — both agents get identical tools,
because they are the same agent built twice. The decision is which gateway
ROUTE the agent's MCP traffic is pointed at, and the platform team makes that
decision from the verdict, behind the agent's back.

So: same server, same tools, two routes in front of it. /mcp is ungated and
/mcp-gated parks every mutating call at a human. See
yaml/agentgateway/10-mcp-routes.yaml.

Cluster state is in-memory; a restart resets it. The point is that a mutation
is observable, not that it is durable.
"""
from __future__ import annotations

import contextlib
import os
from datetime import datetime, timezone
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

# FastMCP auto-enables DNS rebinding protection when its (unused here) internal
# `host` setting defaults to 127.0.0.1, which then rejects the in-cluster
# gateway Host header with a 421. We sit behind agentgateway, so disable it.
_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)


# ─── Mock cluster ─────────────────────────────────────────────────────────────
class MockCluster:
    """A tiny fixed cluster with one obviously-sick workload.

    `checkout` is crash-looping on OOM. That gives the agent a real diagnosis to
    reach and a real remediation to propose, which is what makes the HITL prompt
    meaningful rather than arbitrary.
    """

    def __init__(self) -> None:
        self.deployments: dict[str, dict[str, Any]] = {
            "checkout": {"namespace": "shop", "replicas": 3, "ready": 1, "image": "checkout:1.8.2"},
            "catalogue": {"namespace": "shop", "replicas": 2, "ready": 2, "image": "catalogue:2.1.0"},
            "payments": {"namespace": "shop", "replicas": 2, "ready": 2, "image": "payments:4.0.1"},
        }
        self.pods: list[dict[str, Any]] = [
            {"name": "checkout-7d4f8c9b5-2xk4p", "namespace": "shop", "deployment": "checkout",
             "status": "CrashLoopBackOff", "restarts": 47, "lastState": "OOMKilled"},
            {"name": "checkout-7d4f8c9b5-9wmzt", "namespace": "shop", "deployment": "checkout",
             "status": "CrashLoopBackOff", "restarts": 44, "lastState": "OOMKilled"},
            {"name": "checkout-7d4f8c9b5-lp8vn", "namespace": "shop", "deployment": "checkout",
             "status": "Running", "restarts": 2, "lastState": "OOMKilled"},
            {"name": "catalogue-5b9c7d8f4-hh2qr", "namespace": "shop", "deployment": "catalogue",
             "status": "Running", "restarts": 0, "lastState": None},
            {"name": "catalogue-5b9c7d8f4-t7xdw", "namespace": "shop", "deployment": "catalogue",
             "status": "Running", "restarts": 0, "lastState": None},
            {"name": "payments-6f8d9c4b7-kk3ml", "namespace": "shop", "deployment": "payments",
             "status": "Running", "restarts": 1, "lastState": None},
            {"name": "payments-6f8d9c4b7-zz9tv", "namespace": "shop", "deployment": "payments",
             "status": "Running", "restarts": 0, "lastState": None},
        ]
        self.audit: list[dict[str, Any]] = []

    def now(self) -> str:
        return datetime.now(timezone.utc).isoformat()

    def record(self, op: str, **detail: Any) -> None:
        self.audit.append({"ts": self.now(), "op": op, **detail})


cluster = MockCluster()

mcp = FastMCP("sre-tools", stateless_http=True, transport_security=_TS)


# ─── Read-only tools ──────────────────────────────────────────────────────────
@mcp.tool()
def list_pods(namespace: str = "shop") -> dict:
    """List pods in a namespace with their status and restart counts.

    Start here. The restart counts are what point at the unhealthy workload.
    """
    pods = [p for p in cluster.pods if p["namespace"] == namespace]
    if not pods:
        return {"namespace": namespace, "pods": [], "note": "no pods in this namespace"}
    return {
        "namespace": namespace,
        "pods": pods,
        "unhealthy": [p["name"] for p in pods if p["status"] != "Running"],
    }


@mcp.tool()
def get_pod_logs(pod: str, namespace: str = "shop", lines: int = 20) -> dict:
    """Fetch the last N log lines for a pod.

    A crash-looping pod returns its pre-restart output, which is where the OOM
    evidence is.
    """
    match = next((p for p in cluster.pods if p["name"] == pod and p["namespace"] == namespace), None)
    if match is None:
        return {"error": f"pod {namespace}/{pod} not found"}

    if match["deployment"] == "checkout":
        body = [
            "INFO  starting checkout service v1.8.2",
            "INFO  connected to payments upstream",
            "INFO  cache warm: 12000 entries",
            "WARN  heap usage 82% of limit (512Mi)",
            "WARN  heap usage 91% of limit (512Mi)",
            "WARN  gc pause 1840ms",
            "ERROR allocation failed while building basket index",
            "FATAL container terminated: OOMKilled (exit 137)",
        ]
    else:
        body = [
            f"INFO  starting {match['deployment']} service",
            "INFO  healthz ok",
            "INFO  serving on :8080",
        ]
    return {"pod": pod, "namespace": namespace, "lines": body[-lines:], "lastState": match["lastState"]}


@mcp.tool()
def describe_deployment(name: str, namespace: str = "shop") -> dict:
    """Show a deployment's replica counts and image."""
    dep = cluster.deployments.get(name)
    if dep is None or dep["namespace"] != namespace:
        return {"error": f"deployment {namespace}/{name} not found"}
    return {"name": name, **dep}


# ─── Mutating tools ───────────────────────────────────────────────────────────
# These are the ones a platform team wants a human on when the agent that calls
# them has not been cleared. Nothing here marks them as sensitive: the MCP
# protocol has no notion of "this tool is dangerous". That judgement lives
# outside the agent and outside the tool server, which is the point of the lab.
@mcp.tool()
def restart_deployment(name: str, namespace: str = "shop") -> dict:
    """Roll-restart a deployment. Every pod is replaced.

    Mutating: this drops in-flight requests on the affected pods.
    """
    dep = cluster.deployments.get(name)
    if dep is None or dep["namespace"] != namespace:
        return {"error": f"deployment {namespace}/{name} not found"}

    for pod in cluster.pods:
        if pod["deployment"] == name:
            pod["status"] = "Running"
            pod["restarts"] = 0
            pod["lastState"] = None
    dep["ready"] = dep["replicas"]
    cluster.record("restart", namespace=namespace, deployment=name)
    return {"restarted": True, "deployment": name, "namespace": namespace,
            "ready": f"{dep['ready']}/{dep['replicas']}"}


@mcp.tool()
def scale_deployment(name: str, replicas: int, namespace: str = "shop") -> dict:
    """Scale a deployment to a replica count.

    Mutating: scaling to 0 takes the workload offline.
    """
    dep = cluster.deployments.get(name)
    if dep is None or dep["namespace"] != namespace:
        return {"error": f"deployment {namespace}/{name} not found"}
    if replicas < 0:
        return {"error": "replicas must be >= 0"}

    prev = dep["replicas"]
    dep["replicas"] = replicas
    dep["ready"] = min(dep["ready"], replicas)
    cluster.record("scale", namespace=namespace, deployment=name, **{"from": prev, "to": replicas})
    return {"scaled": True, "deployment": name, "namespace": namespace,
            "from": prev, "to": replicas}


# ─── Introspection (plain HTTP, not MCP) ──────────────────────────────────────
# Used by the scripts to prove a mutation did or did not reach the server. A
# rejected call must leave no audit entry.
async def health(_request):
    return JSONResponse({"status": "ok"})


async def state(_request):
    return JSONResponse(
        {
            "deployments": cluster.deployments,
            "unhealthy": [p["name"] for p in cluster.pods if p["status"] != "Running"],
            "audit": cluster.audit[-20:],
        }
    )


async def reset(_request):
    global cluster
    cluster = MockCluster()
    return JSONResponse({"reset": True})


# ─── Starlette router ─────────────────────────────────────────────────────────
# FastMCP's streamable-HTTP app owns a session manager whose run() async context
# must be active before any request is handled. Mounting the sub-app into a
# parent Starlette does NOT invoke the sub-app's own lifespan, so it has to be
# threaded through the parent's lifespan explicitly. Miss this and every MCP
# request fails with a session-manager error that reads like a transport bug.
@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


app = Starlette(
    routes=[
        Route("/healthz", health),
        Route("/state", state),
        Route("/reset", reset, methods=["POST"]),
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
