#!/usr/bin/env python3
"""Five small tests against the standalone OpenClaw 2.0 gateway container.

Each test is one `openclaw agent` turn run inside the gateway container, and each asserts on
the harness's own state on disk (workspace files) or on the returned tool summary, not on
prose alone. Results are written to captures/baseline-<test>.json.

  CAPTURES=... WORKSPACE=... python3 baseline-test.py [workspace|memory|skill|browser|all]
"""
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

CONTAINER = os.environ.get("BASELINE_CONTAINER", "openclaw-baseline-openclaw-gateway-1")
CAPTURES = Path(os.environ["CAPTURES"])
WORKSPACE = Path(os.environ["WORKSPACE"])
CLI = ["docker", "exec", CONTAINER, "node", "dist/index.js"]
CAPTURES.mkdir(parents=True, exist_ok=True)


def ask(name, message, timeout=240):
    result = subprocess.run(CLI + ["agent", "--session-id", f"lab-{name}-{uuid.uuid4()}", "--message", message, "--json"],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr[-1500:])
    body = json.loads(result.stdout[result.stdout.index("{"):])
    assert body.get("status") == "ok", body
    meta = body["result"]["meta"]
    record = {"prompt": message,
              "response": "\n".join(p.get("text", "") for p in body["result"]["payloads"]),
              "model": meta["agentMeta"]["model"], "provider": meta["agentMeta"]["provider"],
              "tools": meta.get("toolSummary", {}), "session": meta["agentMeta"]["sessionId"]}
    (CAPTURES / f"baseline-{name}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"--- {name}\n{record['response']}\n    tools: {record['tools']}", flush=True)
    return record


def test_workspace():
    marker = WORKSPACE / "lab-marker.txt"
    if marker.exists():
        marker.unlink()
    ask("workspace", "Create lab-marker.txt in your workspace containing exactly OPENCLAW-HARNESS-STATE. "
                     "Read it back with a tool and report the contents. Complete only this request.")
    assert marker.read_text().strip() == "OPENCLAW-HARNESS-STATE", "marker not written by the agent"
    print("[PASS] workspace: the agent wrote lab-marker.txt in its workspace")


def test_memory():
    ask("remember", "Remember that the code name for this lab is BLUE-HERON. Persist it in MEMORY.md in the "
                    "workspace. Complete only this request.")
    assert "BLUE-HERON" in (WORKSPACE / "MEMORY.md").read_text(), "MEMORY.md does not contain the code name"
    recall = ask("recall", "What is the code name I asked you to remember in an earlier conversation? "
                           "Consult your workspace memory. Do not guess.")
    assert "BLUE-HERON" in recall["response"], recall["response"]
    print("[PASS] memory: a new session recalled the code name from MEMORY.md")


def test_skill():
    skill = ask("skill", "Use the lab-inspector skill. Follow its instructions and report the observed results. "
                         "Complete only this request.")
    assert "2026.8.1" in skill["response"], skill["response"]
    assert "OPENCLAW-HARNESS-STATE" in skill["response"], skill["response"]
    print("[PASS] skill: the local lab-inspector skill reported the runtime and the workspace marker")


def test_browser():
    status = json.loads(subprocess.check_output(CLI + ["browser", "start", "--json"], text=True, timeout=90))
    (CAPTURES / "baseline-browser-status.json").write_text(json.dumps(status, indent=2) + "\n")
    assert status.get("running") is True, status
    page = ask("browser", "Use the managed browser tool to open https://mastertheagent.com/solo/ and report the "
                          "visible main page heading. Do not use web_fetch. Complete only this request.")
    assert "browser" in page["tools"].get("tools", []), page["tools"]
    assert "agentic" in page["response"].lower(), page["response"]
    print(f"[PASS] browser: managed {status.get('chosenBrowser')} (headless={status.get('headless')}) read the public page")


TESTS = {"workspace": test_workspace, "memory": test_memory, "skill": test_skill, "browser": test_browser}
selected = sys.argv[1:] or ["all"]
for name in (list(TESTS) if selected == ["all"] else selected):
    TESTS[name]()
