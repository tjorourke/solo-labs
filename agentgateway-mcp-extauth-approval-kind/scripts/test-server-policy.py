#!/usr/bin/env python3
"""Test an existing OSS lab without creating or deleting a cluster.

Requires the seeded u-2 and u-3 users. Approves deletion of u-2, rejects u-3.
Restart only this lab's users-mcp deployment before repeating the test.
Forward hitl-extauth-admin to localhost:18081 (or set ADMIN_URL) before running.

Checks the split of work: native MCP authorization on the users-mcp backend
hides and refuses wipe_users, the ConfigMap's approve list parks delete_user,
and everything else passes ext-auth untouched.
"""
import concurrent.futures
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

GATEWAY = os.environ.get("MCP_URL", "http://localhost:30081/mcp")
ADMIN = os.environ.get("ADMIN_URL", "http://localhost:18081")


def request(url, body=None, session=None):
    headers = {"Accept": "application/json, text/event-stream"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            return response.status, response.headers, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read().decode()


def message(text):
    """Return the JSON-RPC message from a JSON or a one-event SSE body."""
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[6:])
    return json.loads(text) if text.strip().startswith("{") else None


def admin(path, body=None):
    status, _, text = request(ADMIN + path, body)
    assert status in (200, 204), (path, status)
    return json.loads(text) if text else None


def rpc(method, params=None, session=None, ident=1):
    body = {"jsonrpc": "2.0", "id": ident, "method": method}
    if params is not None:
        body["params"] = params
    return request(GATEWAY, body, session)


def main():
    print("Executed", datetime.now(ZoneInfo("Europe/London")).strftime("%Y-%m-%d %H:%M:%S %Z"), flush=True)
    policy = admin("/policy")
    assert "error" not in policy, policy
    assert policy["servers"] == {"users-mcp": {"approve": ["delete_.*"]}}, policy
    print("GET /policy", json.dumps(policy, sort_keys=True), flush=True)
    assert not admin("/pending")["pending"], "do not run while another review is pending"
    status, headers, _ = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "server-policy-test", "version": "1"}})
    assert status == 200, ("initialize", status)
    # agentgateway's MCP backend issues the session, so every later frame carries it.
    sid = headers.get("mcp-session-id")
    assert sid, "MCP backend issued no session"
    status, _, _ = request(GATEWAY, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    assert status in (200, 202, 204), ("initialized", status)
    status, _, text = rpc("tools/list", session=sid)
    names = [t["name"] for t in message(text)["result"]["tools"]]
    assert status == 200 and names == ["get_users", "delete_user"], ("tools/list", status, names)
    assert not admin("/pending")["pending"], "handshake parked"
    print("tools/list", names, flush=True)
    print("PASS initialize and tools/list pass without parking; wipe_users hidden, names unprefixed", flush=True)
    status, _, text = rpc("tools/call", {"name": "get_users", "arguments": {}}, sid, 2)
    assert status == 200 and "u-2" in text and "u-3" in text, "restart the lab users-mcp deployment to restore seeded users"
    print("PASS users-mcp/get_users allowed without approval, seeded users present", flush=True)
    wipe_status, _, text = rpc("tools/call", {"name": "wipe_users", "arguments": {}}, sid, 3)
    error = (message(text) or {}).get("error", {})
    assert wipe_status == 400 and error.get("code") == -32602, ("wipe_users", wipe_status, text)
    assert not admin("/pending")["pending"], "wipe_users parked"
    status, _, metrics = request(ADMIN + "/metrics")
    assert 'hitl_extauth_verdicts_total{server="users-mcp",tool="wipe_users",verdict="allow"}' in metrics
    print("wipe_users HTTP", wipe_status, json.dumps(error), flush=True)
    print("PASS users-mcp/wipe_users passed ext-auth, then refused by native MCP authorization", flush=True)
    for ident, user, approved in [(4, "u-2", True), (5, "u-3", False)]:
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(rpc, "tools/call", {"name": "delete_user", "arguments": {"id": user}}, sid, ident)
            deadline = time.monotonic() + 15
            pending = None
            while time.monotonic() < deadline:
                data = admin("/pending")
                if data["pending"]:
                    pending = data["pending"][0]
                    break
                assert not future.done(), "delete returned without parking"
                time.sleep(0.1)
            assert pending, "no pending delete"
            assert pending["serverName"] == "users-mcp" and pending["toolName"] == "delete_user" and pending["toolArgs"] == {"id": user}, pending
            assert not future.done(), "delete did not remain blocked"
            print("GET /pending", json.dumps(data, sort_keys=True), flush=True)
            status, _, metrics = request(ADMIN + "/metrics")
            assert status == 200 and 'hitl_extauth_approval_needed_total{server="users-mcp",tool="delete_user"}' in metrics
            assert "hitl_extauth_pending 1" in metrics
            print("PASS delete_user parked; metrics identify users-mcp and delete_user", flush=True)
            admin("/decide/" + pending["id"], {"approved": approved, "reason": "server-scoped policy replay"})
            status, _, result = future.result(timeout=20)
            if approved:
                assert status == 200 and "u-2" in result and '"isError":true' not in result.replace(" ", ""), (status, result)
            else:
                assert status == 403 and "server-scoped policy replay" in result, (status, result)
                print("rejected", status, result, flush=True)
            print("PASS " + ("approval forwards delete_user" if approved else "rejection blocks delete_user"), flush=True)
    status, _, text = rpc("tools/call", {"name": "get_users", "arguments": {}}, sid, 6)
    assert status == 200 and "u-2" not in text and "u-3" in text, "backend state disagrees with decisions"
    assert not admin("/pending")["pending"], "queue not empty"
    print("PASS u-2 deleted and rejected u-3 retained; queue empty", flush=True)
    print("Second-server isolation: Go unit-tested only; no second MCP server is deployed.", flush=True)
    print("PASS cluster left running; no teardown", flush=True)


if __name__ == "__main__":
    main()
