#!/usr/bin/env python3
"""Live assertions against the lab cluster; mock usage is exactly 120 tokens/call.

Fresh budget resource names isolate each run from previous Redis counters.
Only resources owned by this lab are reset. The final state is intentionally
left visible: increased budgets and Alice's key revoked.
"""
import json
import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
STARTED = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
KUBE = ["kubectl", "--context", os.environ.get("LAB_CONTEXT", "kind-agw-virtual-keys"),
        "-n", "agentgateway-system"]


def kc(*args, obj=None):
    return subprocess.check_output(KUBE + list(args), text=True,
                                   input=json.dumps(obj) if obj is not None else None)


def apply(obj):
    kc("apply", "-f", "-", obj=obj)


def wait_for(check, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(1)
    raise AssertionError(f"Timed out: {description}")


def request(user=None, model="virtual-key-demo", extra_headers=None, raw_body=None):
    headers = {"Content-Type": "application/json"}
    if user:
        headers["Authorization"] = f"Bearer vk-demo-{user}-not-for-production"
    headers.update(extra_headers or {})
    req = urllib.request.Request(BASE + "/v1/chat/completions", headers=headers,
        data=raw_body if raw_body is not None else json.dumps({"model": model, "messages": [
            {"role": "user", "content": "hello"}]}).encode())
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def expect(user, status, label, model="virtual-key-demo", **kwargs):
    actual, body = request(user, model, **kwargs)
    assert actual == status, f"{label}: expected {status}, got {actual}: {body}"
    if status == 200:
        assert json.loads(body)["usage"]["total_tokens"] == 120, body
        expected_model = {"silver": "resolved-silver", "gold": "resolved-gold"}.get(model, model)
        assert json.loads(body)["model"] == expected_model, f"Alias did not resolve: {body}"
    print(f"PASS {label}: HTTP {status}", flush=True)
    # Debits happen after the response; avoid racing the next admission.
    time.sleep(1)


def logs():
    return kc("logs", "deployment/virtual-keys", "--since-time=" + STARTED)


def proxy_identity():
    pods = json.loads(kc("get", "pods", "-l", "gateway.networking.k8s.io/gateway-name=virtual-keys", "-o", "json"))
    assert pods["items"], "Gateway pod selector matched no pods"
    return sorted((p["metadata"]["uid"], sum(c["restartCount"] for c in
                  p["status"].get("containerStatuses", []))) for p in pods["items"])


keys = json.loads(kc("create", "--dry-run=client", "-f", str(ROOT / "yaml/virtual-keys.yaml"), "-o", "json"))
assert all("keyHash" in json.loads(v) and "key" not in json.loads(v)
           for v in keys["data"].values())
for user, value in keys["data"].items():
    assert json.loads(value)["keyHash"] == "sha256:" + hashlib.sha256(
        f"vk-demo-{user}-not-for-production".encode()).hexdigest(), f"Wrong hash for {user}"
apply(keys)
budget = json.loads(kc("create", "--dry-run=client", "-f", str(ROOT / "yaml/budgets.yaml"), "-o", "json"))
kc("delete", "enterpriseagentgatewaybudget", "-l", "lab=virtual-keys", "--ignore-not-found")
budget["metadata"]["name"] = "virtual-keys-test-" + uuid.uuid4().hex[:8]
# Restore the fixture prices after any previous manual experiments.
catalog = json.loads(kc("create", "--dry-run=client", "-f", str(ROOT / "yaml/model-catalog.yaml"), "-o", "json"))
apply(catalog)
initial_proxy = proxy_identity()

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
BASE = f"http://127.0.0.1:{port}"
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    metrics_port = sock.getsockname()[1]
forward = subprocess.Popen(KUBE + ["port-forward", "deployment/virtual-keys", f"{port}:8080", f"{metrics_port}:15020"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    def ready():
        if forward.poll() is not None:
            raise RuntimeError("kubectl port-forward exited")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            return False
    wait_for(ready, "port-forward")
    # No lab budgets exist during warm-up, so reloading last run's prices cannot
    # consume this run's allowance. ConfigMap volume propagation is asynchronous.
    def initial_price():
        status, body = request("dave")
        assert status == 200, f"Warm-up failed: {status} {body}"
        return "agw.ai.usage.cost.total=1.20" in logs()
    wait_for(initial_price, "initial catalogue price", timeout=180)
    # Before fresh budgets exist, distinguish a policy 403 from a budget 429.
    expect("alice", 200, "Alice: silver alias allowed and rewritten", model="silver")
    expect("alice", 403, "Alice: gold alias denied", model="gold")
    expect("bob", 200, "Bob: silver alias allowed", model="silver")
    expect("bob", 200, "Bob: gold alias allowed and rewritten", model="gold")
    expect("alice", 403, "Raw gold model cannot bypass alias permission", model="resolved-gold")
    expect("bob", 403, "Unknown model denied even for a gold-capable key", model="unknown")
    expect("alice", 403, "Spoofed tier header grants no access", model="gold",
           extra_headers={"x-model-tier": "gold"})
    expect("alice", 403, "Missing model denied", raw_body=b'{"messages":[]}')
    expect("alice", 403, "Malformed JSON denied", raw_body=b'not-json')
    if os.environ.get("LAB_MODELS_ONLY") == "1":
        budget["spec"]["budgets"][0]["limit"]["amount"] = 100000
        budget["spec"]["budgets"][1]["limit"]["amount"] = 50
        apply(budget)
        kc("wait", "enterpriseagentgatewaybudget/" + budget["metadata"]["name"],
           "--for=condition=Accepted", "--timeout=90s")
        print("Model demo ready: four keys, 100,000 tokens/key and $50 for engineering.", flush=True)
        sys.exit(0)
    apply(budget)
    kc("wait", "enterpriseagentgatewaybudget/" + budget["metadata"]["name"],
       "--for=condition=Accepted", "--timeout=90s")
    time.sleep(5)
    expect(None, 401, "missing key")
    expect("invalid", 401, "unknown key")
    expect("alice", 200, "Alice: first 120 tokens / $1.20 simulated cost")
    expect("alice", 200, "Alice: cost-centre Audit allows another request")
    expect("alice", 200, "Alice: crossing 250-token allowance completes")
    expect("alice", 429, "Alice: per-key token budget blocks")
    expect("bob", 200, "Bob: independent token allowance")
    expect("bob", 200, "Bob: crossing shared $5 team allowance completes")
    expect("carol", 429, "Carol: unused key blocked by shared team spend")
    expect("dave", 200, "Dave: different team and cost centre unaffected")

    output = logs()
    for value in ('lab.cost_center="cc-product"', 'lab.team="engineering"',
                  'lab.virtual_key="alice"', "agw.ai.usage.cost.total=1.20",
                  'outcome="over_limit_audit"', "cost-centre-audit",
                  "per-key-tokens", "engineering-spend"):
        assert value in output, f"Missing log evidence: {value}"
    print("PASS logs contain identity, custom cost centre, priced cost and audit budget", flush=True)

    with urllib.request.urlopen(f"http://127.0.0.1:{metrics_port}/metrics", timeout=10) as response:
        metrics = response.read().decode()
    assert any('user_id="alice"' in line and 'team="engineering"' in line
               and line.startswith("agentgateway_gen_ai_client_token_usage_sum{")
               for line in metrics.splitlines()), "Missing per-user token metric"
    assert any('status="Exact"' in line and 'virtual-key-demo' in line
               and line.startswith("agentgateway_cost_catalog_lookups_total{")
               for line in metrics.splitlines()), "Mock model was not priced by the catalogue"
    print("PASS per-user/team token metrics and Exact catalogue lookup", flush=True)

    if os.environ.get("LAB_SHOWCASE") == "1":
        print("Demo ready: four keys, exhausted team budget, per-key limits and cost-centre Audit.", flush=True)
        sys.exit(0)

    budget["spec"]["budgets"][0]["limit"]["amount"] = 100000
    budget["spec"]["budgets"][1]["limit"]["amount"] = 50
    apply(budget)
    # Each unsuccessful attempt is a 429; stop on the first successful call.
    wait_for(lambda: request("alice")[0] == 200, "live budget increase")
    print("PASS budget limits updated without upgrading or restarting AGW", flush=True)

    rates = json.loads(catalog["data"]["catalog.json"])
    rates["providers"]["openai"]["models"]["virtual-key-demo"]["rates"] = {
        "input": "20000", "output": "20000"}
    catalog["data"]["catalog.json"] = json.dumps(rates)
    apply(catalog)
    def repriced():
        status, body = request("dave")
        assert status == 200, f"Price probe failed: {status} {body}"
        return "agw.ai.usage.cost.total=2.40" in logs()
    wait_for(repriced, "catalogue ConfigMap reload ($1.20 -> $2.40)", timeout=180)
    print("PASS live catalogue price change: same 120 tokens now cost $2.40 (simulated)", flush=True)

    del keys["data"]["alice"]
    apply(keys)
    wait_for(lambda: request("alice")[0] == 401, "Alice key revocation")
    expect("carol", 200, "Carol: another key still works after Alice revocation")
    print("PASS hashed-key revocation propagated without restarting AGW", flush=True)
    assert proxy_identity() == initial_proxy, "Gateway pods restarted during update checks"
    print("PASS gateway pod UID and restart counts unchanged", flush=True)
    print("All live checks passed. Test budgets remain visible; Alice is revoked.", flush=True)
finally:
    forward.terminate()
    try:
        forward.wait(timeout=5)
    except subprocess.TimeoutExpired:
        forward.kill()
        forward.wait()
