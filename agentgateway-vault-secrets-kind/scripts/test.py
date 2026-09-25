#!/usr/bin/env python3
"""Live assertions against the lab cluster.

Two headline proof points:
  A. Rotating the OpenAI key in Vault reaches the mock backend with no
     gateway restart (bounded by the CSI driver's rotation-poll interval,
     not the EnterpriseAgentgatewayExternalSecret's refreshInterval).
  B. Corrupting a virtual key's hash in Vault propagates through ESO to a
     live 401 (bounded by the ExternalSecret's refreshInterval).
Plus: the two Vault roles are proven least-privilege (each denied the
other's path), and the raw OpenAI key is proven to never land in a
Kubernetes Secret.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STARTED = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
CTX = os.environ.get("LAB_CONTEXT", "kind-agw-vault-secrets")
OSS = os.environ.get("LAB_EDITION") == "oss"
KUBE = ["kubectl", "--context", CTX, "-n", "agentgateway-system"]
INITIAL_OPENAI_KEY = "sk-vault-demo-openai-key-v1"
ROTATED_OPENAI_KEY = "sk-vault-demo-openai-key-v2"


def kc(*args, obj=None):
    return subprocess.check_output(KUBE + list(args), text=True,
                                   input=json.dumps(obj) if obj is not None else None)


def vault(*args):
    return subprocess.check_output(
        ["kubectl", "--context", CTX, "-n", "vault", "exec", "vault-0", "--"] + list(args),
        text=True)


def wait_for(check, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(2)
    raise AssertionError(f"Timed out: {description}")


def request(path, key=None, model="vault-secrets-demo"):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(BASE + path, headers=headers,
        data=json.dumps({"model": model, "messages": [{"role": "user", "content": "hello"}]}).encode())
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def proxy_identity():
    pods = json.loads(kc("get", "pods", "-l", "gateway.networking.k8s.io/gateway-name=vault-secrets", "-o", "json"))
    assert pods["items"], "Gateway pod selector matched no pods"
    return sorted((p["metadata"]["uid"], sum(c["restartCount"] for c in
                  p["status"].get("containerStatuses", []))) for p in pods["items"])


def vault_role_denied(role, sa):
    """Mints a fresh token for `sa`, logs into Vault as `role`, and asserts the
    resulting Vault token cannot read the *other* role's secret path."""
    other_path = "secret/data/virtual-keys/alice" if role == "agentgateway" else "secret/data/openai-api-key"
    jwt = subprocess.check_output(
        ["kubectl", "--context", CTX, "-n", "agentgateway-system", "create", "token", sa, "--duration=10m"],
        text=True).strip()
    login = json.loads(vault("vault", "write", "-format=json", "auth/kubernetes/login",
                              f"role={role}", f"jwt={jwt}"))
    token = login["auth"]["client_token"]
    result = subprocess.run(
        ["kubectl", "--context", CTX, "-n", "vault", "exec", "vault-0", "--", "sh", "-c",
         f"VAULT_TOKEN={token} vault kv get {other_path}"],
        capture_output=True, text=True)
    return result.returncode != 0 and "permission denied" in (result.stdout + result.stderr).lower()


# Put Vault back to the state quick.sh up seeds, so the test can run twice:
# a previous run leaves the rotated provider key and Alice's corrupted hash behind.
vault("vault", "kv", "put", "secret/openai-api-key", f"api-key={INITIAL_OPENAI_KEY}")
seed = subprocess.check_output([sys.executable, str(ROOT / "scripts" / "seed-virtual-keys.py")], text=True)
for line in seed.splitlines():
    if "/alice " in line:
        user_json = line.split("value='", 1)[1].rstrip("'")
        vault("vault", "kv", "put", "secret/virtual-keys/alice", f"value={user_json}")

keys = json.loads(kc("get", "secret", "virtual-key-hashes", "-o", "json"))
assert "alice" in keys["data"], "virtual-key-hashes Secret missing alice (ESO sync failed)"
if not OSS:  # vacuous on OSS, where nothing reads the provider key
    raw_secrets = kc("get", "secrets", "-o", "yaml")
    assert INITIAL_OPENAI_KEY not in raw_secrets, "Raw OpenAI key found in a Kubernetes Secret"
    print("PASS OpenAI key never lands in a Kubernetes Secret", flush=True)

initial_proxy = proxy_identity()

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
BASE = f"http://127.0.0.1:{port}"
forward = subprocess.Popen(KUBE + ["port-forward", "service/vault-secrets", f"{port}:8080"],
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

    # --- Flow A: provider key via CSI/Vault, no Kubernetes Secret involved.
    # Enterprise only: EnterpriseAgentgatewayExternalSecret has no OSS equivalent.
    if not OSS:
        def initial_key_seen():
            status, body = request("/v1/openai")
            assert status == 200, f"warm-up request failed: {status} {body}"
            return json.loads(body)["received_authorization"] == f"Bearer {INITIAL_OPENAI_KEY}"
        wait_for(initial_key_seen, "initial provider key materialized from Vault", timeout=180)
        print("PASS provider backend received the initial Vault-sourced key", flush=True)

        vault("vault", "kv", "put", "secret/openai-api-key", f"api-key={ROTATED_OPENAI_KEY}")

        def rotated_key_seen():
            status, body = request("/v1/openai")
            assert status == 200, f"post-rotation request failed: {status} {body}"
            return json.loads(body)["received_authorization"] == f"Bearer {ROTATED_OPENAI_KEY}"
        wait_for(rotated_key_seen, "rotated provider key propagated via CSI", timeout=180)
        print("PASS Vault key rotation reached the backend with no gateway restart", flush=True)
        assert proxy_identity() == initial_proxy, "Gateway pods restarted during provider-key rotation"
        print("PASS gateway pod UID and restart counts unchanged after rotation", flush=True)

    # --- Flow B: virtual keys via ESO ---
    def all_keys_accepted():
        return all(request("/v1/chat/completions", key=f"vk-demo-{user}-not-for-production")[0] == 200
                   for user in ("alice", "bob", "carol", "dave"))
    # Waits out one ESO refreshInterval when the reset above restored Alice's hash.
    wait_for(all_keys_accepted, "all four virtual keys accepted", timeout=120)
    print("PASS all four virtual keys authenticate", flush=True)

    status, body = request("/v1/chat/completions")
    assert status == 401, f"missing key: expected 401, got {status}: {body}"
    print("PASS missing key rejected", flush=True)

    vault("vault", "kv", "put", "secret/virtual-keys/alice",
          'value={"keyHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","metadata":{"id":"alice"}}')

    def alice_revoked():
        status, _ = request("/v1/chat/completions", key="vk-demo-alice-not-for-production")
        return status == 401
    wait_for(alice_revoked, "Vault-side hash corruption propagated via ESO", timeout=120)
    print("PASS Alice's revoked hash propagated through ESO to a live 401", flush=True)

    status, body = request("/v1/chat/completions", key="vk-demo-carol-not-for-production")
    assert status == 200, f"Carol should still work: {status} {body}"
    print("PASS Carol's key still works after Alice's revocation", flush=True)
    assert proxy_identity() == initial_proxy, "Gateway pods restarted during revocation checks"
    print("PASS gateway pod UID and restart counts unchanged after revocation", flush=True)

    # --- Negative test: least-privilege separation between the two Vault roles ---
    if not OSS:  # the OSS run has no provider-key flow, so no agentgateway role
        assert vault_role_denied("agentgateway", "enterprise-agentgateway"), \
            "agentgateway role could read the virtual-keys path"
        print("PASS agentgateway role denied read on secret/data/virtual-keys/*", flush=True)
    assert vault_role_denied("eso-virtual-keys", "eso-virtual-keys-reader"), \
        "eso-virtual-keys role could read the openai-api-key path"
    print("PASS eso-virtual-keys role denied read on secret/data/openai-api-key", flush=True)

    if os.environ.get("LAB_SHOWCASE") == "1":
        print("Demo ready: rotated provider key, Alice revoked, both roles least-privilege.", flush=True)
        sys.exit(0)

    print("All live checks passed.", flush=True)
finally:
    forward.terminate()
    try:
        forward.wait(timeout=5)
    except subprocess.TimeoutExpired:
        forward.kill()
        forward.wait()
