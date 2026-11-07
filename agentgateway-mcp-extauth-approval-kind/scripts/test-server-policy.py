#!/usr/bin/env python3
"""Test an existing OSS lab without creating or deleting a cluster.

Requires the seeded u-2 and u-3 users. Approves deletion of u-2, rejects u-3.
Restart only this lab's users-mcp deployment before repeating the test.
Forward hitl-extauth-admin to localhost:18081 before running.
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
    print("Executed", datetime.now(ZoneInfo("Europe/London")).strftime("%Y-%m-%d %H:%M:%S GMT"), flush=True)
    policy = admin("/policy")
    assert "error" not in policy, policy
    assert policy["servers"] == {"users-mcp": {"allow": ["get_.*"], "approve": ["delete_.*"], "deny": []}}, policy
    print("GET /policy", json.dumps(policy, sort_keys=True), flush=True)
    assert not admin("/pending")["pending"], "do not run while another review is pending"
    status, headers, _ = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "server-policy-test", "version": "1"}})
    assert status == 200, ("initialize", status)
    sid = headers.get("mcp-session-id")
    # users-mcp uses stateless_http=True, so no session header is required.
    status, _, _ = request(GATEWAY, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    assert status in (200, 202, 204), ("initialized", status)
    status, _, text = rpc("tools/list", session=sid)
    assert status == 200 and "delete_user" in text, ("tools/list", status)
    assert not admin("/pending")["pending"], "handshake parked"
    print("PASS initialize and tools/list pass without parking", flush=True)
    status, _, text = rpc("tools/call", {"name": "get_users", "arguments": {}}, sid, 2)
    assert status == 200 and "u-2" in text and "u-3" in text, "restart the lab users-mcp deployment to restore seeded users"
    print("PASS users-mcp/get_users allowed, seeded users present", flush=True)
    status, _, text = rpc("tools/call", {"name": "wipe_users", "arguments": {}}, sid, 3)
    assert status == 403 and "default deny" in text, ("unlisted tool", status, text)
    assert not admin("/pending")["pending"], "unlisted tool parked"
    print("PASS users-mcp/wipe_users default-denied without parking", flush=True)
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
            assert status == (200 if approved else 403), ("decision", status, result)
            if approved:
                assert "u-2" in result and '"isError":true' not in result.replace(" ", ""), result
            print("PASS " + ("approval forwards delete_user" if approved else "rejection blocks delete_user"), flush=True)
    status, _, text = rpc("tools/call", {"name": "get_users", "arguments": {}}, sid, 6)
    assert status == 200 and "u-2" not in text and "u-3" in text, "backend state disagrees with decisions"
    assert not admin("/pending")["pending"], "queue not empty"
    print("PASS u-2 deleted and rejected u-3 retained; queue empty", flush=True)
    print("Second-server isolation: Go unit-tested only; no second MCP server is deployed.", flush=True)
    print("PASS cluster left running; no teardown", flush=True)


if __name__ == "__main__":
    main()
