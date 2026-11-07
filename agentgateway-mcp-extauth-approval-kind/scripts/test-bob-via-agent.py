#!/usr/bin/env python3
"""Bob asks the kagent dba-agent to remove a user. Never prints tokens.

Port-forwards Keycloak, the kagent controller and the hitl-extauth admin API,
gets Bob's Keycloak token, sends one A2A message to the agent through the
kagent controller with Bob's bearer token, waits for the tool call to park,
saves GET /pending, approves it and prints the agent's reply.
"""
import concurrent.futures, json, os, pathlib, subprocess, sys, time, urllib.parse, urllib.request, uuid

CTX = "kind-" + os.environ.get("CLUSTER", "hitl-sts-part2")
NS = "mcp-extauth-demo"
PROMPT = os.environ.get("PROMPT", "Tom Reyes left the company last week. Please remove him from the users directory.")
FORWARDS = [("keycloak", "svc/keycloak", 28080, 8080), ("kagent", "svc/kagent-controller", 28083, 8083), (NS, "svc/hitl-extauth-admin", 28081, 8081)]

def http(url, data=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def main():
    procs = [subprocess.Popen(["kubectl", "--context", CTX, "-n", ns, "port-forward", svc, f"{lp}:{rp}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for ns, svc, lp, rp in FORWARDS]
    try:
        time.sleep(3)
        form = urllib.parse.urlencode({"grant_type": "password", "client_id": "dba-client", "username": "bob", "password": "bob"}).encode()
        status, body = http("http://localhost:28080/realms/hitl-part2/protocol/openid-connect/token", form, {"content-type": "application/x-www-form-urlencoded"})
        assert status == 200, f"Keycloak {status}"
        bob = json.loads(body)["access_token"]
        assert not json.loads(http("http://localhost:28081/pending")[1])["pending"], "queue not empty before the test"
        msg = {"jsonrpc": "2.0", "id": 1, "method": "message/send", "params": {"message": {"kind": "message", "role": "user", "messageId": str(uuid.uuid4()), "parts": [{"kind": "text", "text": PROMPT}]}}}
        a2a = "http://localhost:28083/api/a2a/" + NS + "/dba-agent/"
        with concurrent.futures.ThreadPoolExecutor() as pool:
            fut = pool.submit(http, a2a, json.dumps(msg).encode(), {"content-type": "application/json", "authorization": "Bearer " + bob}, 600)
            data = None
            end = time.monotonic() + 240
            while time.monotonic() < end:
                data = json.loads(http("http://localhost:28081/pending")[1])
                if data["pending"]: break
                if fut.done(): raise AssertionError("agent replied before any call parked: " + fut.result()[1][:600])
                time.sleep(0.5)
            assert data and data["pending"], "nothing parked"
            raw = json.dumps(data)
            assert bob not in raw and "Bearer " not in raw, "credential leak"
            p = data["pending"][0]
            print(json.dumps(data, separators=(",", ":")))
            assert p.get("user") == "bob" and p.get("agent") == "dba-agent" and p.get("toolName") == "delete_user", "unexpected pending entry"
            ev = pathlib.Path(__file__).resolve().parents[1] / "evidence"
            (ev / "pending-bob-via-agent.json").write_text(json.dumps(data, indent=2) + "\n")
            print("PASS queue shows user bob and agent dba-agent for", p["toolName"], json.dumps(p["toolArgs"]))
            st, _ = http("http://localhost:28081/decide/" + p["id"], json.dumps({"approved": True, "reason": "offboarding ticket checked"}).encode(), {"content-type": "application/json"})
            assert st in (200, 204), f"decide {st}"
            status, body = fut.result(timeout=300)
        assert status == 200, f"A2A {status}"
        result = json.loads(body).get("result", {})
        parts = result.get("parts") or [pt for m in result.get("history", []) if m.get("role") == "agent" for pt in m.get("parts", [])] or result.get("status", {}).get("message", {}).get("parts", [])
        print("AGENT:", " ".join(pt.get("text", "") for pt in parts).strip())
        print("PASS approve released the agent's delete_user")
    finally:
        for p in procs: p.terminate()

if __name__ == "__main__": main()
