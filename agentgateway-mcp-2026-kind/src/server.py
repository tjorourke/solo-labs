#!/usr/bin/env python3
# ops-mcp: a minimal MCP 2026-07-28 server, Python stdlib only.
#
# Implements the modern protocol surface this lab demonstrates:
#   server/discover, tools/list, tools/call with MRTR
#   (input_required + integrity-protected requestState), and the
#   io.modelcontextprotocol/tasks extension (tasks/get, tasks/update,
#   tasks/cancel) with an approval gate mid-pipeline.
#
# The whole point of the stateless rewrite is that this fits in one file
# with no SDK: every request stands on its own, and MRTR continuation
# state rides in the payload, HMAC-protected, instead of in a session.

import base64
import hashlib
import hmac
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("MCP_STATE_SECRET", "demo-secret").encode()
POD = socket.gethostname()
PROTOCOL = "2026-07-28"
STATE_TTL_SECONDS = 300

STALE_FILES = [
    "/data/tmp/build-2019.log",
    "/data/tmp/core.1842",
    "/data/tmp/report-old.csv",
]

PIPELINE_STAGES = ["fetch sources", "build images", "run tests"]

TOOLS = [
    {
        "name": "list_stale_files",
        "description": "List files under /data/tmp that have not been touched in 90 days.",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "cleanup_files",
        "description": "Delete the stale files under /data/tmp. Asks a human for confirmation first (MRTR elicitation).",
        "inputSchema": {"type": "object"},
    },
    {
        "name": "run_pipeline",
        "description": "Run the release pipeline: build, test, then pause for a human deploy approval. Long-running; returns an MCP Task.",
        "inputSchema": {"type": "object"},
    },
]


# ── requestState: opaque to the client, integrity-protected by us ──
# The spec says requestState is attacker-controlled input: bind what it
# protects (tool, expiry) and reject anything that fails verification.

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
        if not hmac.compare_digest(want, mac):
            return None
        payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        if payload.get("tool") != expect_tool:
            return None
        if payload.get("exp", 0) < time.time():
            return None
        return payload
    except Exception:
        return None


# ── tasks extension state (one replica owns its tasks) ──

TASKS = {}
TASKS_LOCK = threading.Lock()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def touch(task, status=None, message=None):
    if status:
        task["status"] = status
    if message is not None:
        task["statusMessage"] = message
    task["lastUpdatedAt"] = now_iso()


def task_view(task):
    out = {
        "resultType": "complete",
        "taskId": task["id"],
        "status": task["status"],
        "createdAt": task["createdAt"],
        "lastUpdatedAt": task["lastUpdatedAt"],
        "ttlMs": 600000,
    }
    if task["status"] in ("working", "input_required"):
        out["pollIntervalMs"] = 2000
    if task["status"] == "input_required":
        out["inputRequests"] = task["inputRequests"]
    if task["status"] == "completed":
        out["result"] = task["result"]
    if task["status"] == "failed":
        out["error"] = task["error"]
    if task.get("statusMessage"):
        out["statusMessage"] = task["statusMessage"]
    return out


def pipeline_worker(task):
    for stage in PIPELINE_STAGES:
        with TASKS_LOCK:
            if task["cancelRequested"]:
                touch(task, "cancelled", "cancelled before %s" % stage)
                return
            touch(task, message="stage: %s" % stage)
        log("task %s stage: %s" % (task["id"], stage))
        time.sleep(4)

    with TASKS_LOCK:
        if task["cancelRequested"]:
            touch(task, "cancelled", "cancelled before deploy approval")
            return
        task["inputRequests"] = {
            "approve_deploy": {
                "method": "elicitation/create",
                "params": {
                    "mode": "form",
                    "message": "Build and tests passed. Deploy release 2026.31 to production?",
                    "requestedSchema": {
                        "type": "object",
                        "properties": {"approve": {"type": "boolean"}},
                        "required": ["approve"],
                    },
                },
            }
        }
        touch(task, "input_required", "waiting for deploy approval")
    log("task %s paused: input_required (deploy approval)" % task["id"])

    task["approvalEvent"].wait()
    with TASKS_LOCK:
        if task["cancelRequested"]:
            touch(task, "cancelled", "cancelled while awaiting approval")
            return
        approved = task["approved"]
        task.pop("inputRequests", None)
        if not approved:
            touch(task, "completed", "deploy declined")
            task["result"] = {
                "content": [
                    {
                        "type": "text",
                        "text": "deploy declined by operator; pipeline abandoned after tests (pod %s)" % POD,
                    }
                ],
                "isError": True,
            }
            log("task %s completed with isError=true (declined)" % task["id"])
            return
        touch(task, "working", "stage: deploy to production")
    log("task %s resumed: deploying" % task["id"])
    time.sleep(4)
    with TASKS_LOCK:
        touch(task, "completed", "pipeline finished")
        task["result"] = {
            "content": [
                {
                    "type": "text",
                    "text": "release 2026.31 deployed: %d stages ok (pod %s)" % (len(PIPELINE_STAGES) + 1, POD),
                }
            ],
            "isError": False,
        }
    log("task %s completed" % task["id"])


# ── JSON-RPC handling ──

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
    meta = params.get("_meta") or {}

    if name == "list_stale_files":
        listing = "\n".join(STALE_FILES)
        return rpc_result(
            rid, text_result("3 stale files (served by pod %s):\n%s" % (POD, listing))
        )

    if name == "cleanup_files":
        state = params.get("requestState")
        if state is not None:
            payload = verify_state(state, "cleanup_files")
            if payload is None:
                log("cleanup_files: rejected requestState (bad signature, wrong tool or expired)")
                return rpc_error(rid, -32602, "invalid or expired requestState")
            answer = (params.get("inputResponses") or {}).get("confirm_cleanup") or {}
            accepted = answer.get("action") == "accept" and (answer.get("content") or {}).get("confirm") is True
            if not accepted:
                log("cleanup_files: declined by operator")
                return rpc_result(rid, text_result("cleanup declined; nothing deleted (pod %s)" % POD))
            log("cleanup_files: confirmed, deleting %d files" % len(payload["files"]))
            return rpc_result(
                rid,
                text_result(
                    "deleted %d files: %s (resumed on pod %s)" % (len(payload["files"]), ", ".join(payload["files"]), POD)
                ),
            )
        if not client_declared(meta, "elicitation"):
            return rpc_result(
                rid,
                text_result("client did not declare the elicitation capability; refusing to delete without confirmation", True),
            )
        log("cleanup_files: pausing with input_required (asked on pod %s)" % POD)
        return rpc_result(
            rid,
            {
                "resultType": "input_required",
                "inputRequests": {
                    "confirm_cleanup": {
                        "method": "elicitation/create",
                        "params": {
                            "mode": "form",
                            "message": "Delete 3 stale files under /data/tmp?",
                            "requestedSchema": {
                                "type": "object",
                                "properties": {"confirm": {"type": "boolean"}},
                                "required": ["confirm"],
                            },
                        },
                    }
                },
                "requestState": sign_state(
                    {"tool": "cleanup_files", "files": STALE_FILES, "exp": int(time.time()) + STATE_TTL_SECONDS}
                ),
            },
        )

    if name == "run_pipeline":
        if not client_declared(meta, "extensions", "io.modelcontextprotocol/tasks"):
            return rpc_result(
                rid,
                text_result("client did not declare io.modelcontextprotocol/tasks; refusing to run a multi-minute pipeline synchronously", True),
            )
        task_id = "task-%s" % base64.urlsafe_b64encode(os.urandom(6)).decode().rstrip("=")
        task = {
            "id": task_id,
            "status": "working",
            "createdAt": now_iso(),
            "lastUpdatedAt": now_iso(),
            "statusMessage": "starting",
            "cancelRequested": False,
            "approved": False,
            "approvalEvent": threading.Event(),
        }
        # The handle is a promise: the task is durably created before we respond.
        with TASKS_LOCK:
            TASKS[task_id] = task
        threading.Thread(target=pipeline_worker, args=(task,), daemon=True).start()
        log("run_pipeline: created %s" % task_id)
        return rpc_result(
            rid,
            {
                "resultType": "task",
                "taskId": task_id,
                "status": "working",
                "createdAt": task["createdAt"],
                "lastUpdatedAt": task["lastUpdatedAt"],
                "ttlMs": 600000,
                "pollIntervalMs": 2000,
            },
        )

    return rpc_error(rid, -32602, "unknown tool: %s" % name)


def handle(body):
    rid = body.get("id")
    method = body.get("method", "")
    params = body.get("params") or {}

    if method.startswith("notifications/"):
        return None  # 202, no body

    if method == "server/discover":
        return rpc_result(
            rid,
            {
                "resultType": "complete",
                "supportedVersions": [PROTOCOL],
                "capabilities": {
                    "tools": {},
                    "extensions": {"io.modelcontextprotocol/tasks": {}},
                },
                "serverInfo": {"name": "ops-mcp", "version": "1.0.0"},
                "ttlMs": 60000,
                "cacheScope": "public",
            },
        )

    if method == "initialize":
        # Legacy clients still get an answer during the deprecation window.
        return rpc_result(
            rid,
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "ops-mcp", "version": "1.0.0"},
            },
        )

    if method == "tools/list":
        return rpc_result(
            rid,
            {
                "resultType": "complete",
                "tools": TOOLS,
                "ttlMs": 60000,
                "cacheScope": "public",
            },
        )

    if method == "tools/call":
        return handle_tools_call(rid, params)

    if method == "tasks/get":
        with TASKS_LOCK:
            task = TASKS.get(params.get("taskId", ""))
            if task is None:
                return rpc_error(rid, -32602, "unknown task")
            return rpc_result(rid, task_view(task))

    if method == "tasks/update":
        with TASKS_LOCK:
            task = TASKS.get(params.get("taskId", ""))
            if task is None:
                return rpc_error(rid, -32602, "unknown task")
            answer = (params.get("inputResponses") or {}).get("approve_deploy") or {}
            task["approved"] = answer.get("action") == "accept" and (answer.get("content") or {}).get("approve") is True
        log("tasks/update: approval received (approved=%s)" % task["approved"])
        task["approvalEvent"].set()
        return rpc_result(rid, {"resultType": "complete"})

    if method == "tasks/cancel":
        with TASKS_LOCK:
            task = TASKS.get(params.get("taskId", ""))
            if task is None:
                return rpc_error(rid, -32602, "unknown task")
            task["cancelRequested"] = True
            view = task_view(task)
        task["approvalEvent"].set()
        log("tasks/cancel: cancellation requested for %s (cooperative)" % task["id"])
        return rpc_result(rid, view)

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
        log("%s (Mcp-Method: %s)" % (body.get("method"), self.headers.get("Mcp-Method", "-")))
        response = handle(body)
        if response is None:
            self._send(202)
        else:
            self._send(200, response)


if __name__ == "__main__":
    log("ops-mcp serving MCP %s on :8000" % PROTOCOL)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
