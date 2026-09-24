#!/usr/bin/env python3
"""Verify hybrid routing with a one-token budget on an unseen test identity.

No existing user's limit is changed. Makes short real model calls, restores the
temporary budget in finally. No identity is added to any gateway or policy data.
"""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--signing-key", type=Path, required=True)
    args = parser.parse_args()
    dashboard = load("30-dashboard.py")
    kube = ["kubectl", "--context", args.context, "-n", "agentgateway-system"]

    def run(*parts, **kwargs):
        return subprocess.run(kube + list(parts), text=True, check=True, capture_output=True, **kwargs)

    user = "native-budget-" + uuid.uuid4().hex[:8]
    key = serialization.load_pem_private_key(args.signing_key.read_bytes(), password=None)
    enc = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
    part = enc(b'{"alg":"RS256","kid":"lab-key"}') + "." + enc(json.dumps({"iss": "https://identity.lab", "aud": "model-gateway", "sub": user, "groups": ["model-private", "model-frontier"], "exp": int(time.time()) + 1800}).encode())
    token = part + "." + enc(key.sign(part.encode(), padding.PKCS1v15(), hashes.SHA256()))
    budget = {"apiVersion": "enterpriseagentgateway.solo.io/v1alpha1", "kind": "EnterpriseAgentgatewayBudget", "metadata": {"name": user, "namespace": "agentgateway-system"},
              "spec": {"budgets": [{"name": user, "subject": {"user": user, "modelPool": "approved-frontier"}, "limit": {"amount": 1, "unit": "Tokens"}, "window": {"unit": "Day"}, "onBudgetExceeded": "Block"}]}}
    mark = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    def request(path):
        trace = uuid.uuid4().hex
        req = urllib.request.Request(args.base_url.rstrip("/") + path, data=json.dumps({"model": "claude-sonnet-5", "max_tokens": 8, "messages": [{"role": "user", "content": "Explain what a Python list comprehension is"}]}).encode(), headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json", "anthropic-version": "2023-06-01", "traceparent": f"00-{trace}-0123456789abcdef-01"})
        try:
            response = urllib.request.urlopen(req, timeout=90)
        except urllib.error.HTTPError as error:
            response = error
        return response.status, json.loads(response.read()), trace

    try:
        run("apply", "-f", "-", input=json.dumps(budget))
        time.sleep(4)
        for attempt in range(8):
            status, body, trace = request("/v1/chat/completions")
            assert status in (200, 429), (status, body)
            if status == 429:
                break
            time.sleep(4)
        assert status == 429, "the temporary frontier budget never blocked"
        assert body["error"]["type"] == "insufficient_quota", body
        status, body, trace = request("/v1/messages")
        assert status == 429 and body["error"]["type"] == "insufficient_quota", (status, body)
        time.sleep(2)
        for line in run("logs", "deploy/decision-gateway", "--since-time=" + mark).stdout.splitlines():
            dashboard.on_gateway(line)
        card = next(c for c in dashboard.cards if (c.get("request_key") or "").startswith(trace + ":"))
        assert card["user"] == user and card["pool"] == "approved-frontier" and card["status"] == "429", card
        # The access log can name a selected endpoint before budget enforcement;
        # selection is not an upstream call or a model response.
        assert card["prompt"] and not card.get("answered_by"), card
        print("PASS budget 429 in Chat Completions and Messages; native access-log card includes identity, prompt and pool")
    finally:
        run("delete", "EnterpriseAgentgatewayBudget", user, "--ignore-not-found")


if __name__ == "__main__":
    main()
