"""Read-only layer board. Policy presence and observed evidence are distinct.

Gateway counters are per current pod. Log counts cover retained logs since this
lab's namespace was created, and inbound-only ztunnel entries avoid double counting.
Nothing in this module sends demonstration traffic or changes cluster state.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.request

CTX = "kind-mesh1"
AGENT_ID = "spiffe://mesh1/ns/dd-agents/sa/defence-agent"
_cache = None
_lock = threading.Lock()
_history = {"uid": None, "workload": {}, "tools": {}}
_state_token = (None, 0, "")
LAYERS = [
    ("egress", "Outside destination", "example.com through dd-egress", "Waypoint TCP RBAC denials"),
    ("workload", "Workload identity", "Only the gateways reach the tool server", "Retained inbound ztunnel refusal logs"),
    ("caller", "Caller identity", "Signed token at the front door; only the front door reaches the agent", "Front door 401 / JwtAuth"),
    ("tools", "Tool permissions", "The agent's identity may investigate; only the operator changes records", "Retained bulk-close refusals at dd-waypoint"),
    ("content", "Personal data", "Reject sample email addresses before the model call", "Waypoint guardrail Reject counter"),
    ("rate", "Request rate", "Three agent requests per minute per caller", "Front door 429 / DirectResponse"),
    ("detection", "Detection", "Add caller identity to gateway metrics", "Identity-labelled refusal samples"),
]


def kubectl(*args):
    try:
        p = subprocess.run(["kubectl", "--context", CTX, "--request-timeout=5s", *args],
                           capture_output=True, text=True, timeout=7)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(str(e)) from e
    if p.returncode:
        raise RuntimeError(p.stderr.strip()[-350:])
    return p.stdout


def samples(text, name):
    result = []
    for line in text.splitlines():
        m = re.fullmatch(re.escape(name) + r'(?:\{(.*)\})?\s+([\d.eE+\-]+)', line)
        if m:
            labels = dict(re.findall(r'(\w+)="((?:\\.|[^"\\])*)"', m[1] or ""))
            result.append((labels, float(m[2])))
    return result


def workload_refusals(text, since):
    records = {}
    for line in text.splitlines():
        try:
            r = json.loads(line[line.index("{"):])
        except (ValueError, json.JSONDecodeError):
            continue
        if (r.get("src.namespace") == "dd-agents" and r.get("src.identity") == AGENT_ID
                and r.get("dst.namespace") == "dd-tools"
                and r.get("direction") == "inbound" and r.get("time", "") >= since
                and "policy rejection" in r.get("error", "")):
            records[r.get("conn_id", r["time"])] = r
    return list(records.values())


def tool_refusals(text):
    """Bulk-close calls dd-waypoint refused for the agent's own identity."""
    return [l for l in text.splitlines()
            if 'error="mcp: Unknown tool: close_all_incidents"' in l and "mcp.method.name=tools/call" in l
            and "src.identity=" + AGENT_ID + " " in l]


def incident_state(objects, uid):
    """Read actual incident records via the gateway, authenticated with a lab JWT."""
    global _state_token
    gateway = next((o for o in objects if o["kind"] == "Gateway" and o["metadata"]["name"] == "dd-gateway"), {})
    addresses = gateway.get("status", {}).get("addresses", [])
    if not addresses:
        return None
    if _state_token[0] != uid or time.monotonic() - _state_token[1] > 300:
        source = Path(__file__).resolve().parent.parent / "demo-scripts/defence/identity.py"
        p = subprocess.run([sys.executable, str(source), "token", "--user", "board"],
                           capture_output=True, text=True, timeout=3)
        if p.returncode:
            raise RuntimeError("Lab identity is not ready for the incident-state reader")
        _state_token = (uid, time.monotonic(), p.stdout.strip())
    req = urllib.request.Request("http://" + addresses[0]["value"] + "/ops-state",
                                 headers={"Authorization": "Bearer " + _state_token[2]})
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.load(response)


def _collect():
    ns = kubectl("get", "ns", "dd-agents", "--ignore-not-found", "-o", "json")
    if not ns.strip():
        return {"ok": True, "reset": True, "layers": [
            {"id": key, "name": name, "detail": detail, "source": source, "status": "Not deployed", "count": 0}
            for key, name, detail, source in LAYERS], "errors": [], "evidence": [], "requests": [], "agent": None, "task": None, "incidents": None}
    metadata = json.loads(ns)["metadata"]
    created = metadata["creationTimestamp"]
    if _history["uid"] != metadata["uid"]:
        _history.update(uid=metadata["uid"], workload={}, tools={})
    errors, outputs = {}, {}
    jobs = {
        "gateway": ("-n", "dd-gateway", "get", "pod,enterpriseagentgatewaypolicy,ratelimitconfig,gateway", "-o", "json"),
        "egress": ("-n", "dd-agents", "get", "pod,authorizationpolicy,agent", "-o", "json"),
        "tools": ("-n", "dd-tools", "get", "authorizationpolicy", "-o", "json"),
        "ztunnel": ("-n", "istio-system", "logs", "-l", "app=ztunnel", "--since-time=" + created, "--tail=10000"),
    }
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {key: pool.submit(kubectl, *args) for key, args in jobs.items()}
        for key, future in futures.items():
            try:
                outputs[key] = future.result()
            except RuntimeError as e:
                errors[key] = str(e)
        objects = {k: json.loads(outputs[k])["items"] if k in outputs else []
                   for k in ("gateway", "egress", "tools")}

        def pod(group, gateway):
            return next((o["metadata"]["name"] for o in objects[group] if o["kind"] == "Pod"
                         and o["metadata"].get("labels", {}).get("gateway.networking.k8s.io/gateway-name") == gateway
                         and any(c.get("type") == "Ready" and c.get("status") == "True"
                                 for c in o.get("status", {}).get("conditions", []))), None)

        gw, mw, wp = pod("gateway", "dd-gateway"), pod("gateway", "dd-waypoint"), pod("egress", "dd-egress")
        reads = {}
        if gw:
            reads["metrics"] = ("get", "--raw", f"/api/v1/namespaces/dd-gateway/pods/{gw}:15020/proxy/metrics")
        if mw:
            reads["mesh_metrics"] = ("get", "--raw", f"/api/v1/namespaces/dd-gateway/pods/{mw}:15020/proxy/metrics")
            reads["mesh_logs"] = ("-n", "dd-gateway", "logs", mw, "--since-time=" + created, "--tail=3000")
        if wp:
            reads["waypoint"] = ("-n", "dd-agents", "exec", wp, "--", "pilot-agent", "request", "GET", "stats?filter=rbac")
        futures = {key: pool.submit(kubectl, *args) for key, args in reads.items()}
        for key, future in futures.items():
            try:
                outputs[key] = future.result()
            except RuntimeError as e:
                errors[key] = str(e)

    def exists(group, name):
        return any(o["kind"] == "AuthorizationPolicy" and o["metadata"]["name"] == name for o in objects[group])
    # Front door (people): 401 and 429. Mesh waypoint (the agent): tool refusals and guardrails.

    def attached(name):
        p = next((o for o in objects["gateway"] if o["kind"] == "EnterpriseAgentgatewayPolicy"
                  and o["metadata"]["name"] == name), None)
        if not p:
            return False
        conditions = [c for a in p.get("status", {}).get("ancestors", []) for c in a.get("conditions", [])
                      if c["type"] in ("Accepted", "Attached")]
        return len(conditions) >= 2 and all(c["status"] == "True" and c.get("observedGeneration") == p["metadata"]["generation"] for c in conditions)

    metrics, mesh_metrics = outputs.get("metrics", ""), outputs.get("mesh_metrics", "")
    requests = samples(metrics, "agentgateway_requests_total")
    refusals = workload_refusals(outputs.get("ztunnel", ""), created)
    tools = tool_refusals(outputs.get("mesh_logs", ""))
    # A busy shared ztunnel rotates its logs quickly. Preserve observations already
    # made by this console, keyed by namespace UID so reset never carries them over.
    for r in refusals:
        _history["workload"][r.get("conn_id", r["time"])] = r
    for line in tools:
        _history["tools"][line] = line
    refusals = list(_history["workload"].values())
    tools = list(_history["tools"].values())
    rbac = re.search(r'^tcp\.rbac\.denied: (\d+)$', outputs.get("waypoint", ""), re.M)
    counters = {
        "egress": int(rbac[1]) if rbac else (0 if "waypoint" in outputs or not wp else None),
        "workload": len(refusals) if "ztunnel" in outputs else None,
        "caller": sum(n for l, n in requests if l.get("status") == "401" and l.get("reason") == "JwtAuth"),
        "tools": len(tools) if "mesh_logs" in outputs else (None if mw else 0),
        "content": sum(n for l, n in samples(mesh_metrics, "agentgateway_guardrail_checks_total") if l.get("phase") == "Request" and l.get("action") == "Reject"),
        "rate": sum(n for l, n in requests if l.get("status") == "429" and l.get("reason") == "DirectResponse"),
        "detection": sum(n for l, n in requests if l.get("caller") and l.get("status") in ("401", "429")),
    }
    if "metrics" in errors:
        for key in ("caller", "rate", "detection"):
            counters[key] = None
    if "mesh_metrics" in errors:
        counters["content"] = None
    policy_names = {"caller": "caller-identity", "tools": "tool-permissions", "content": "reject-personal-data",
                    "rate": "per-person-rate", "detection": "identity-metrics"}
    present = {key: any(o["kind"] == "EnterpriseAgentgatewayPolicy" and o["metadata"]["name"] == name
                        for o in objects["gateway"]) for key, name in policy_names.items()}
    configured = {"egress": exists("egress", "outside-deny"),
                  "workload": exists("tools", "gateway-only"),
                  "caller": attached("caller-identity") and exists("egress", "agent-front-door"),
                  **{key: attached(name) for key, name in (
                      ("tools", "tool-permissions"),
                      ("content", "reject-personal-data"), ("rate", "per-person-rate"), ("detection", "identity-metrics"))}}
    layers = []
    for key, name, detail, source in LAYERS:
        count = counters[key]
        status = "Open"
        if present.get(key) and not configured[key]:
            status = "Pending / rejected"
        if configured[key]:
            status = ("Observing" if key == "detection" else "Enforced") if count else "Applied; awaiting evidence"
        if key in policy_names and not (mw if key in ("tools", "content") else gw):
            status = "Waiting for gateway"
        groups = {"workload": ("tools", "ztunnel"), "egress": ("egress", "waypoint"),
                  "tools": ("gateway", "mesh_logs"), "content": ("gateway", "mesh_metrics")}.get(key, ("gateway", "metrics"))
        if any(g in errors for g in groups) or count is None:
            status = "Unknown"
        layers.append({"id": key, "name": name, "detail": detail, "source": source, "status": status,
                       "count": count, "applied": configured[key]})
    evidence = [f'{r["src.identity"]} -> {r.get("dst.service", r["dst.namespace"])}: {r["error"]}' for r in refusals[-2:]]
    evidence += tools[-2:]
    agent = next((o for o in objects["egress"] if o["kind"] == "Agent" and o["metadata"]["name"] == "defence-agent"), None)
    if agent:
        agent = {"name": "defence-agent", "type": agent["spec"]["type"],
                 "ready": any(c["type"] == "Ready" and c["status"] == "True" for c in agent.get("status", {}).get("conditions", []))}
    task = None
    taskfile = Path(os.environ.get("TMPDIR", "/tmp")) / "defence-lab/last-agent-task.json"
    try:
        if agent and taskfile.stat().st_mtime >= datetime.fromisoformat(created).timestamp():
            result = json.loads(taskfile.read_text()).get("result", {})
            parts = [p for message in result.get("history", []) for p in message.get("parts", [])]
            task = {"state": result.get("status", {}).get("state", "unknown"),
                    "calls": [p["data"] for p in parts if p.get("metadata", {}).get("kagent_type") == "function_call"],
                    "answer": " ".join(p.get("text", "") for a in result.get("artifacts", []) for p in a.get("parts", []))}
    except (OSError, ValueError, KeyError):
        pass
    incidents = None
    try:
        incidents = incident_state(objects["gateway"], metadata["uid"])
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
        errors["incident state"] = str(e)
    requests += samples(mesh_metrics, "agentgateway_requests_total")
    return {"ok": True, "reset": False, "layers": layers, "errors": [f"{k}: {v}" for k, v in errors.items()],
            "evidence": evidence, "requests": [{"labels": l, "count": n} for l, n in requests],
            "gatewayPod": gw, "waypointPod": mw, "since": created, "agent": agent, "task": task, "incidents": incidents}


def state():
    global _cache
    with _lock:
        if _cache and time.monotonic() - _cache[0] < 1.5:
            return _cache[1]
        try:
            result = _collect()
        except (RuntimeError, ValueError, KeyError) as e:
            result = {"ok": False, "error": str(e)}
        _cache = (time.monotonic(), result)
        return result
