#!/usr/bin/env python3
"""Two synthetic tickets through the gateway; no provider credential in this client."""
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get("EVIDENCE_DIR", ROOT / "evidence"))
OUT.mkdir(parents=True, exist_ok=True)
CTX = "kind-openai-decisions"

def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def ready(port, proc):
    for _ in range(150):
        if proc.poll() is not None:
            raise RuntimeError("Port-forward exited before becoming ready")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("Port-forward did not become ready")

def validate(reply, expected):
    assert reply["model"].startswith("gpt-6-luna"), reply
    answers = {a["name"]: a for a in reply["answers"]}
    assert set(answers) == {"queue", "needs_human", "severity"}, answers
    assert answers["queue"]["type"] == "choice"
    assert answers["queue"]["choice"] == expected, answers
    assert 0 <= answers["needs_human"]["probability"] <= 1
    assert answers["needs_human"]["type"] == "predicate"
    assert answers["severity"]["type"] == "score"
    assert 0 <= answers["severity"]["score"] <= 2
    for name in ("queue", "severity"):
        assert 0 <= answers[name]["confidence"] <= 1
        assert abs(sum(p["probability"] for p in answers[name]["probabilities"]) - 1) < 0.02
    assert reply["usage"]["input_tokens"] > 0
    return {name: answers[name] for name in answers}

def main():
    port, metrics_port = free_port(), free_port()
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(["kubectl", "--context", CTX, "-n", "agentgateway-system", "port-forward", "deployment/agentgateway-proxy", f"{port}:80", f"{metrics_port}:15020", "--address=127.0.0.1"], stdout=log, stderr=log)
        try:
            ready(port, proc)
            summary = {"tested_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "context": CTX, "tickets": {}}
            for name in ("billing", "shipping"):
                body = (ROOT / "requests" / f"{name}.json").read_bytes()
                request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/decisions", body, {"Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(request, timeout=90) as response:
                        reply = json.load(response)
                except urllib.error.HTTPError as error:
                    detail = error.read().decode()
                    (OUT / f"{name}-error.txt").write_text(f"HTTP {error.code}\n{detail}\n")
                    raise RuntimeError(f"{name}: HTTP {error.code}: {detail}") from error
                (OUT / f"{name}-response.json").write_text(json.dumps(reply, indent=2) + "\n")
                summary["tickets"][name] = validate(reply, name)
                print(name, json.dumps(summary["tickets"][name]))
            with urllib.request.urlopen(f"http://127.0.0.1:{metrics_port}/metrics", timeout=15) as response:
                metrics = response.read().decode()
            lines = [line for line in metrics.splitlines() if "agentgateway_gen_ai_client_token_usage" in line]
            assert any('gen_ai_response_model="gpt-6-luna"' in line and 'gen_ai_token_type="input"' in line and 'gen_ai_operation_name="decisions"' in line for line in lines), "Model-labelled Decisions input token metric missing"
            (OUT / "token-metrics.txt").write_text("\n".join(lines) + "\n")
            summary["metrics_present"] = True
            (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print("PASS: both tickets, three typed answers each, model-labelled token metrics. Cluster left running.")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

if __name__ == "__main__":
    main()
