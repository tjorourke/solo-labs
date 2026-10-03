#!/usr/bin/env python3
"""Agent Substrate demo: drive the load and read the board's state back.

The work is all in demo-scripts/substrate-load.sh, which is the same thing you run
from a terminal. This wraps it so the console can start it, stream what it says, and
show the counts while it runs.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPTS = ROOT.parent / "demo-scripts"
LOAD = SCRIPTS / "substrate-load.sh"
SCOPE = SCRIPTS / "substrate-scope.sh"
CTX = os.environ.get("SUBSTRATE_CTX", "kind-mesh2")
NS = "kagent"
POOL = "kagent-default"
PORT = os.environ.get("SUBSTRATE_SCOPE_PORT", "8123")
BOARD = f"http://localhost:{PORT}"
STIM_LOG = Path(os.environ.get("TMPDIR", "/tmp")) / "substrate-stimulate.log"

DEFAULTS = {"agents": 12, "minutes": 2, "workers": 3}


def kubectl(*args, timeout=20):
    return subprocess.run(
        ["kubectl", "--context", CTX, *args],
        text=True, capture_output=True, timeout=timeout,
    )


def board_up() -> bool:
    try:
        with urllib.request.urlopen(BOARD + "/", timeout=3):
            return True
    except Exception:
        return False


def status() -> dict:
    """What the page needs before anyone presses a button."""
    out = {
        "board": BOARD,
        "board_up": board_up(),
        "context": CTX,
        "cluster": False,
        "workers": 0,
        "agents": 0,
        "ready": 0,
        "running": running(),
        "defaults": DEFAULTS,
        "error": "",
    }
    try:
        pool = kubectl("-n", NS, "get", "workerpool", POOL, "-o", "json")
        if pool.returncode != 0:
            out["error"] = (pool.stderr.strip().split("\n")[-1] or "no substrate on mesh2")[:160]
            return out
        out["cluster"] = True
        spec = json.loads(pool.stdout)
        out["workers"] = spec.get("status", {}).get("replicas") or spec.get("spec", {}).get("replicas") or 0
        agents = kubectl("-n", NS, "get", "sandboxagent", "-l", "scope-load=true", "-o", "json")
        if agents.returncode == 0:
            items = json.loads(agents.stdout).get("items", [])
            out["agents"] = len(items)
            out["ready"] = sum(
                1 for a in items
                for c in a.get("status", {}).get("conditions", [])
                if c.get("type") == "Ready" and c.get("status") == "True"
            )
    except Exception as e:
        out["error"] = str(e)[:160]
    return out


def running() -> bool:
    """Is the stimulator dispatching right now?

    Matched off ps rather than `pgrep -f`, which happily matches any shell whose own
    command line mentions the script — including one that is only asking the question.
    """
    r = subprocess.run(["ps", "-Ao", "command="], capture_output=True, text=True)
    return any(
        line.lstrip().startswith("node ") and "stimulate.mjs" in line
        for line in r.stdout.splitlines()
    )


_COUNT = re.compile(r"^([✓✗…■])")


def tally(path: Path) -> dict:
    """Read the stimulator's own log rather than keeping a second set of books."""
    out = {"sent": 0, "ok": 0, "failed": 0, "queued": 0, "last": ""}
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        m = _COUNT.match(line)
        if not m:
            continue
        mark = m.group(1)
        if mark == "✓":
            out["ok"] += 1
        elif mark == "✗":
            out["failed"] += 1
        elif mark == "…":
            out["queued"] += 1
        if mark in "✓✗":
            out["last"] = line[:140]
    out["sent"] = out["ok"] + out["failed"]
    return out


def stop() -> dict:
    """Chats off, agents removed, viewer down. The button that ends the demo."""
    r = subprocess.run(["bash", str(LOAD), "stop"], text=True, capture_output=True, timeout=180)
    return {"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-2000:]}


def pause() -> dict:
    """Chats off, board stays. The button you press when you have made the point."""
    r = subprocess.run(["bash", str(SCOPE), "pause"], text=True, capture_output=True, timeout=60)
    return {"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-2000:]}


def start(body: dict, emit) -> None:
    """Run substrate-load.sh, stream what it prints, then follow the chats it starts."""
    agents = max(1, min(int(body.get("agents") or DEFAULTS["agents"]), 40))
    minutes = max(1, min(int(body.get("minutes") or DEFAULTS["minutes"]), 10))
    workers = max(1, min(int(body.get("workers") or DEFAULTS["workers"]), 8))

    emit({"type": "status",
          "text": f"{agents} actors on {workers} workers, {CTX}, chats for {minutes} min"})
    if not LOAD.is_file():
        emit({"type": "error", "text": f"missing {LOAD}"})
        return

    # The log is per-run, so clear it before the script starts writing to it or the
    # first tick reports the last demo's numbers.
    try:
        STIM_LOG.unlink()
    except OSError:
        pass

    env = dict(os.environ, AGENTS=str(agents), MINUTES=str(minutes),
                WORKERS=str(workers), SUBSTRATE_CTX=CTX)
    env.pop("KUBECONFIG", None)     # substrate-scope.sh pins its own
    proc = subprocess.Popen(
        ["bash", str(LOAD)], env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=1,
    )
    failed = False
    for line in proc.stdout:
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("✗"):
            failed = True
        emit({"type": "line", "text": line[:400]})
    proc.wait()
    if proc.returncode != 0 or failed:
        emit({"type": "error", "text": "the load did not start — see the lines above"})
        emit({"type": "done", "ok": False})
        return

    emit({"type": "started", "board": BOARD, "minutes": minutes})
    t0 = time.time()
    deadline = t0 + minutes * 60 + 15
    seen = ""
    while time.time() < deadline:
        t = tally(STIM_LOG)
        t.update({
            "type": "tick",
            "elapsed": int(time.time() - t0),
            "total": minutes * 60,
            "running": running(),
        })
        emit(t)
        if t["last"] != seen:
            seen = t["last"]
        if not t["running"] and time.time() - t0 > 10:
            break
        time.sleep(2)
    emit({"type": "done", "ok": True, **tally(STIM_LOG)})
