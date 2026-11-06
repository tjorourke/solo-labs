#!/usr/bin/env python3
# users-mcp: a minimal MCP 2026-07-28 server, Python stdlib only.
#
# Two tools: get_users (read, unguarded) and delete_user (write, gated by
# MRTR: the server pauses with an input_required result carrying an
# HMAC-protected requestState, instead of deleting on the first call).
# The gate lives entirely in this backend's own code -- agentgateway relays
# the MRTR pause/resume exchange, it does not implement the confirmation
# itself. See agentgateway-mcp-2026-kind/src/server.py for the fuller
# MRTR + Tasks reference this is trimmed from.

import base64
import hashlib
import hmac
import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("MCP_STATE_SECRET", "demo-secret").encode()
POD = socket.gethostname()
PROTOCOL = "2026-07-28"
STATE_TTL_SECONDS = 300

USERS = [
    {"id": "u-1", "name": "Priya Shah", "email": "priya.shah@example.com"},
    {"id": "u-2", "name": "Tom Reyes", "email": "tom.reyes@example.com"},
    {"id": "u-3", "name": "Aisha Bello", "email": "aisha.bello@example.com"},
]

TOOLS = [
    {
        "name": "get_users",
        "description": "List users.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "delete_user",
        "description": "Permanently delete a user. Asks a human for confirmation first (MRTR elicitation).",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
    },
]


# -- requestState: opaque to the client, integrity-protected by us --
# The spec says requestState is attacker-controlled input: bind what it
# protects (tool, target id, expiry) and reject anything that fails
# verification. Same construction as the ops-mcp MRTR reference lab.

def sign_state(payload):
    body = (
        base64.urlsafe_b64encode(
            json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
        )
        .decode()
        .rstrip("=")
    )
    mac = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{mac}"


def verify_state(state, expect_tool):
    try:
        body, mac = state.rsplit(".", 1)
        want = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
        if not hmac.compare_digest(mac, want):
            return None
        padded = body + "=" * (-len(body) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        if payload.get("tool") != expect_tool:
            return None
        if payload.get("exp", 0) < time.time():
            return None
        return payload
    except Exception:
        return None


# -- JSON-RPC handling --

def log(msg):
    print("[%s] %s" % (POD, msg), flush=True)


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def rpc_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def client_declared(meta, *path):
    node = (meta or {}).get("io.modelcontextprotocol/clientCapabilities") or {}
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return False
        node = node[key]
    return True


def text_result(text, is_error=False):
    return {
        "resultType": "complete",
        "content": [{"type": "text", "text": text}],
        "isError": is_error,
    }


def handle_tools_call(rid, params):
    name = params.get("name", "")
    args = params.get("arguments") or {}
    meta = params.get("_meta") or {}

    if name == "get_users":
        lines = "\n".join("%s  %s  <%s>" % (u["id"], u["name"], u["email"]) for u in USERS)
        return rpc_result(rid, text_result("%d user(s) (served by pod %s):\n%s" % (len(USERS), POD, lines)))

    if name == "delete_user":
        state = params.get("requestState")

        if state is not None:
            payload = verify_state(state, "delete_user")
            if payload is None:
                log("delete_user: rejected requestState (bad signature, wrong tool or expired)")
                return rpc_error(rid, -32602, "invalid or expired requestState")
            answer = (params.get("inputResponses") or {}).get("confirm_delete") or {}
            accepted = answer.get("action") == "accept" and (answer.get("content") or {}).get("confirm") is True
            uid = payload["id"]
            match = next((u for u in USERS if u["id"] == uid), None)
            if not accepted:
                log("delete_user %s: declined by operator" % uid)
                return rpc_result(rid, text_result("deletion declined; %s not removed (pod %s)" % (uid, POD)))
            if match is None:
                return rpc_result(rid, text_result("no such user: %s" % uid, True))
            USERS.remove(match)
            log("delete_user %s: confirmed, deleted %s" % (uid, match["name"]))
            return rpc_result(
                rid,
                text_result("deleted %s (%s) (resumed on pod %s)" % (uid, match["name"], POD)),
            )

        uid = args.get("id", "")
        match = next((u for u in USERS if u["id"] == uid), None)
        if match is None:
            return rpc_result(rid, text_result("no such user: %s" % uid, True))
        if not client_declared(meta, "elicitation"):
            return rpc_result(
                rid,
                text_result("client did not declare the elicitation capability; refusing to delete without confirmation", True),
            )
        log("delete_user %s: pausing with input_required (asked on pod %s)" % (uid, POD))
        return rpc_result(
            rid,
            {
                "resultType": "input_required",
                "inputRequests": {
                    "confirm_delete": {
                        "method": "elicitation/create",
                        "params": {
                            "mode": "form",
                            "message": "Permanently delete user %s (%s)?" % (uid, match["name"]),
                            "requestedSchema": {
                                "type": "object",
                                "properties": {"confirm": {"type": "boolean"}},
                                "required": ["confirm"],
                            },
                        },
                    }
                },
                "requestState": sign_state(
                    {"tool": "delete_user", "id": uid, "exp": int(time.time()) + STATE_TTL_SECONDS}
                ),
            },
        )

    return rpc_error(rid, -32602, "unknown tool: %s" % name)


def handle(body):
    rid = body.get("id")
    method = body.get("method", "")
    params = body.get("params") or {}

    if method.startswith("notifications/"):
        return None

    if method in ("initialize", "server/discover"):
        return rpc_result(
            rid,
            {
                "protocolVersion": PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "users-mcp", "version": "1.0.0"},
            },
        )

    if method == "tools/list":
        return rpc_result(rid, {"tools": TOOLS})

    if method == "tools/call":
        return handle_tools_call(rid, params)

    return rpc_error(rid, -32601, method)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, payload=None):
        data = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(code)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True, "pod": POD})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/mcp":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except Exception:
            self._send(400, {"error": "invalid JSON"})
            return
        log("%s" % body.get("method"))
        response = handle(body)
        if response is None:
            self._send(202)
        else:
            self._send(200, response)


if __name__ == "__main__":
    log("users-mcp serving MCP on :8000")
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
