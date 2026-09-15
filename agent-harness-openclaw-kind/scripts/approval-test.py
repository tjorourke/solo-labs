#!/usr/bin/env python3
"""OpenClaw's own exec approval: switch exec to allowlist + ask=always, send one turn that runs
`uname -a`, watch the approval appear in the Control UI, approve it once, and check the command
actually ran. The UI is driven through the container's own managed Chromium (playwright-core
over CDP), so no host browser or personal profile is involved.

  CAPTURES=... TOKEN=... python3 approval-test.py
"""
import json
import os
import subprocess
import uuid
from pathlib import Path

CONTAINER = os.environ.get("BASELINE_CONTAINER", "openclaw-baseline-openclaw-gateway-1")
CAPTURES = Path(os.environ["CAPTURES"])
HERE = Path(__file__).resolve().parent
CLI = ["docker", "exec", CONTAINER, "node", "dist/index.js"]


def cli(*args, timeout=60):
    return subprocess.check_output(CLI + list(args), text=True, timeout=timeout)


session = "approval-" + str(uuid.uuid4())
child = None
cli("config", "set", "tools.exec.security", "allowlist")
cli("config", "set", "tools.exec.ask", "always")
try:
    for script in ("capture-ui.mjs", "approve-ui.mjs"):
        subprocess.run(["docker", "cp", str(HERE / script), f"{CONTAINER}:/tmp/{script}"], check=True)
    # Open the authenticated Control UI in the managed browser so it can receive the approval.
    subprocess.run(["docker", "exec", "-e", f"OPENCLAW_GATEWAY_TOKEN={os.environ['TOKEN']}", CONTAINER,
                    "node", "/tmp/capture-ui.mjs"], check=True, timeout=120, stdout=subprocess.DEVNULL)
    child = subprocess.Popen(CLI + ["agent", "--session-id", session, "--message",
                             "Use exec to run exactly uname -a now. Do not reuse earlier results. Wait for approval if requested.",
                             "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    subprocess.run(["docker", "exec", CONTAINER, "node", "/tmp/approve-ui.mjs", session], check=True, timeout=180)
    out, err = child.communicate(timeout=120)
    assert child.returncode == 0, err[-1500:]
    result = json.loads(out[out.index("{"):])
    assert result.get("status") == "ok", result
    payloads = result.get("result", {}).get("payloads", [])
    assert any("Linux" in p.get("text", "") for p in payloads), payloads
    subprocess.run(["docker", "cp", f"{CONTAINER}:/home/node/.openclaw/lab-captures/approval.png", str(CAPTURES / "baseline-approval.png")], check=True)
    subprocess.run(["docker", "cp", f"{CONTAINER}:/home/node/.openclaw/lab-captures/control-ui.png", str(CAPTURES / "baseline-control-ui.png")], check=True)
    (CAPTURES / "baseline-approval.json").write_text(json.dumps({
        "session": session, "command": "uname -a", "decision": "allow-once",
        "result": [p.get("text", "") for p in payloads]}, indent=2) + "\n")
    print("[PASS] approval: uname -a waited for an exec approval in the Control UI, was allowed once, and ran")
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        child.wait(timeout=10)
    cli("config", "set", "tools.exec.security", "full")
    cli("config", "set", "tools.exec.ask", "off")
