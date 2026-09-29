"""Live state of the Agent Substrate lab's worker pool, for its App tab.

Everything comes from the cluster as it is right now: kagent's substrate inventory
(/api/substrate/status on the controller, read through the API server's service
proxy, so no port-forward), and the worker node's process table, which says which
actors have a gVisor sandbox alive at this moment. An actor with no process is a
snapshot on disk; that is the point the view makes.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time

CTX = "kind-substrate"
NS = "kagent"
POOL = "lab-pool"
_cache: tuple[float, dict] | None = None
_lock = threading.Lock()


def _kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", "--context", CTX, *args], capture_output=True, text=True, timeout=8).stdout


def _live_sandboxes() -> set[str]:
    """Actor directories that have a runsc sandbox process on the worker node now."""
    node = _kubectl("-n", NS, "get", "pod", "-l", f"ate.dev/worker-pool={POOL}",
                    "-o", "jsonpath={.items[0].spec.nodeName}").strip()
    if not node:
        return set()
    ps = subprocess.run(["docker", "exec", node, "sh", "-c", "ps -ef | grep '[r]unsc-sandbox'"],
                        capture_output=True, text=True, timeout=5).stdout
    return {m.split(":", 1)[-1] for m in re.findall(r"actors/([^/ ]+)", ps)}


def _ordered(actors: list[dict]) -> list[dict]:
    """Busy actors first, then the lab's own conversation, then the most recently snapshotted."""
    newest_first = sorted(actors, key=lambda a: a["snapshotAt"], reverse=True)
    return sorted(newest_first, key=lambda a: (a["status"] == "Suspended", not a["mine"]))


def state() -> dict:
    global _cache
    with _lock:
        if _cache and time.monotonic() - _cache[0] < 0.5:
            return _cache[1]
        raw = _kubectl("get", "--raw", f"/api/v1/namespaces/{NS}/services/kagent-controller:8083/proxy/api/substrate/status")
        try:
            data = json.loads(raw)["data"]
        except (json.JSONDecodeError, KeyError, TypeError):
            result = {"ok": False, "error": f"no substrate status from kagent on {CTX}"}
            _cache = (time.monotonic(), result)
            return result
        templates = [t for t in data.get("actorTemplates", []) if t.get("workerSelector", "").endswith(f"={POOL}")]
        names = {t["name"]: t.get("harnessName") or t["name"] for t in templates}
        alive = _live_sandboxes()
        try:   # the conversation the lab follows in chapter 6, saved by substrate-lab.sh
            mine = open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "substrate-lab.session")).read().split()[0]
        except (OSError, IndexError):
            mine = ""
        actors = []
        for a in data.get("actors", []):
            if a.get("actorTemplateName") not in names or a.get("atespace") == "ate-golden":
                continue
            snap = re.search(r"/(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)-", a.get("latestSnapshot") or "")
            actors.append({
                "id": a["actorId"], "agent": names[a["actorTemplateName"]], "status": a.get("status"),
                "version": a.get("version"), "snapshotAt": snap.group(1) if snap else "",
                "process": a["actorId"] in alive,
                "mine": bool(mine) and a["actorId"].endswith(mine),
            })
        workers = [w for w in data.get("workers", []) if w.get("workerPool") == POOL]
        pool = next((p for p in data.get("workerPools", []) if p.get("name") == POOL), {})
        result = {
            "ok": True, "pool": POOL, "replicas": pool.get("replicas", len(workers)),
            "workers": [{"pod": w["workerPod"], "ip": w.get("ip", "")} for w in workers],
            "templates": [{"name": t["name"], "agent": names[t["name"]], "phase": t.get("phase"),
                           "golden": t.get("goldenActorId", "")} for t in templates],
            "actors": _ordered(actors),
            "sandboxes": len(alive), "error": "",
        }
        _cache = (time.monotonic(), result)
        return result
