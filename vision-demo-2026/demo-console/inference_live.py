"""Live state of the inference pool, for the inference routing lab's App tab.

Reads each replica's gauges from its own /metrics endpoint, the same numbers the
Endpoint Picker scrapes to score it, and counts where the gateway actually sent
requests from its access log (selected_endpoint). Nothing is simulated here: if
a step re-pins a replica or fires requests, the next poll shows it.
"""
from __future__ import annotations

import calendar
import json
import re
import subprocess
import threading
import time

CTX = "kind-inference"
NS = "inference"
GAUGES = {
    "vllm:kv_cache_usage_perc": "kv",
    "vllm:num_requests_waiting": "waiting",
    "vllm:num_requests_running": "running",
}
_cache: tuple[float, dict] | None = None
_lock = threading.Lock()


def _kubectl(*args: str, timeout: int = 8) -> str:
    return subprocess.run(["kubectl", "--context", CTX, *args], capture_output=True, text=True,
                          timeout=timeout).stdout


def _metrics(pod: str) -> dict:
    raw = _kubectl("get", "--raw", f"/api/v1/namespaces/{NS}/pods/{pod}:8000/proxy/metrics")
    out = {}
    for line in raw.splitlines():
        name = line.split("{", 1)[0].split(" ", 1)[0]
        if name in GAUGES:
            try:
                out[GAUGES[name]] = float(line.rsplit(" ", 1)[1])
            except ValueError:
                pass
    return out


def _routed(ips: dict[str, str]) -> dict:
    """Requests per replica over the last minute and the last ten, and the latest pick."""
    log = _kubectl("-n", NS, "logs", "deploy/inference-gateway", "--since=10m", "--timestamps")
    now = time.time()
    counts = {r: {"minute": 0, "ten": 0} for r in ips}
    last = None
    by_ip = {ip: r for r, ip in ips.items()}
    for line in log.splitlines():
        m = re.search(r"selected_endpoint=([\d.]+):", line)
        if not m or m.group(1) not in by_ip:
            continue
        r = by_ip[m.group(1)]
        counts[r]["ten"] += 1
        stamp = line.split(" ", 1)[0]          # kubectl --timestamps: RFC 3339 in UTC
        try:
            t = calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            t = now
        if now - t <= 60:
            counts[r]["minute"] += 1
        last = r
    return {"counts": counts, "last": last}


def _weights() -> dict:
    cfg = _kubectl("-n", NS, "get", "cm", "vllm-sim-epp", "-o", "jsonpath={.data.default-plugins\\.yaml}")
    weights = {}
    for m in re.finditer(r"pluginRef:\s*(\S+)\s*\n\s*weight:\s*(\d+)", cfg):
        weights[m.group(1)] = int(m.group(2))
    return weights


def state() -> dict:
    global _cache
    with _lock:
        if _cache and time.monotonic() - _cache[0] < 1.5:
            return _cache[1]
        try:
            pods = json.loads(_kubectl("-n", NS, "get", "pods", "-l", "app=vllm-sim", "-o", "json") or "{}")
        except json.JSONDecodeError:
            pods = {}
        replicas, ips = [], {}
        for item in sorted(pods.get("items", []), key=lambda i: i["metadata"].get("labels", {}).get("replica", "")):
            if item["metadata"].get("deletionTimestamp") or item["status"].get("phase") != "Running":
                continue
            name = item["metadata"]["name"]
            replica = item["metadata"].get("labels", {}).get("replica", name)
            if replica in ips:
                continue           # a rollout briefly has two pods; show the newest one only
            ips[replica] = item["status"].get("podIP", "")
            replicas.append({"replica": replica, "pod": name, "ip": ips[replica], **_metrics(name)})
        result = {"ok": bool(replicas), "replicas": replicas, "weights": _weights(), **_routed(ips),
                  "error": "" if replicas else f"no model-server pods in {NS} on {CTX}"}
        _cache = (time.monotonic(), result)
        return result
