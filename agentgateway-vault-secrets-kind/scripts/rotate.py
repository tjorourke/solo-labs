#!/usr/bin/env python3
"""Rotate the provider key in Vault and watch the gateway pick it up.

Writes a new value to secret/openai-api-key, then polls /v1/openai once a
second and prints the Authorization header the mock backend received until it
changes. Prints how long that took and whether any gateway pod restarted.
Pass a key as the first argument, or let the script generate one.
"""
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.request

CTX = os.environ.get("LAB_CONTEXT", "kind-agw-vault-secrets")
KUBE = ["kubectl", "--context", CTX, "-n", "agentgateway-system"]
NEW_KEY = sys.argv[1] if len(sys.argv) > 1 else f"sk-vault-demo-openai-key-{secrets.token_hex(3)}"


def received_authorization(base):
    req = urllib.request.Request(base + "/v1/openai", headers={"Content-Type": "application/json"},
        data=json.dumps({"model": "vault-secrets-demo", "messages": [{"role": "user", "content": "hello"}]}).encode())
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.loads(response.read())["received_authorization"]


def proxy_identity():
    pods = json.loads(subprocess.check_output(KUBE + ["get", "pods", "-l",
        "gateway.networking.k8s.io/gateway-name=vault-secrets", "-o", "json"], text=True))
    return sorted((p["metadata"]["uid"], sum(c["restartCount"] for c in
                  p["status"].get("containerStatuses", []))) for p in pods["items"])


with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
base = f"http://127.0.0.1:{port}"
forward = subprocess.Popen(KUBE + ["port-forward", "service/vault-secrets", f"{port}:8080"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(30):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                break
        except OSError:
            time.sleep(1)
    before = received_authorization(base)
    pods_before = proxy_identity()
    print(f"Backend currently receives: {before}")
    print(f"Writing new key to Vault:   {NEW_KEY}")
    subprocess.check_call(["kubectl", "--context", CTX, "-n", "vault", "exec", "vault-0", "--",
                           "vault", "kv", "put", "secret/openai-api-key", f"api-key={NEW_KEY}"],
                          stdout=subprocess.DEVNULL)
    started = time.monotonic()
    while True:
        seen = received_authorization(base)
        elapsed = time.monotonic() - started
        if seen == f"Bearer {NEW_KEY}":
            break
        if elapsed > 180:
            sys.exit(f"New key not seen after {elapsed:.0f}s; backend still receives {seen}")
        print(f"  {elapsed:4.0f}s  {seen}", flush=True)
        time.sleep(1)
    print(f"Backend now receives:       {seen}  ({elapsed:.0f}s after the Vault write)")
    print("Gateway pods restarted:     " + ("no" if proxy_identity() == pods_before else "YES"))
finally:
    forward.terminate()
    forward.wait(timeout=5)
