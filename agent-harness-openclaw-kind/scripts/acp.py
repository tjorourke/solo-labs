#!/usr/bin/env python3
"""Talk to a kagent AgentHarness over the Agent Client Protocol.

A harness does not answer on A2A like an Agent or SandboxAgent. The kagent controller exposes
one WebSocket per kagent session at /api/agentharnesses/<ns>/<name>/acp/<session>, proxied to
the acp-shim inside the Substrate actor, which bridges to `openclaw acp` over stdio. The flow
is initialize -> session/new -> session/prompt; replies stream back as session/update
notifications and the harness may ask for permission with session/request_permission.

  acp.py --agent openclaw-lab "prompt"              # deny any permission request (default)
  acp.py --agent openclaw-lab --approve "prompt"    # allow-once every request, and print it
  acp.py --capture name ...                         # write the raw JSON-RPC frames to captures/name.jsonl

Standard library only, so it runs wherever the lab scripts run.
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("prompt")
parser.add_argument("--agent", default=os.environ.get("HARNESS", "openclaw-lab"))
parser.add_argument("--namespace", default=os.environ.get("NS", "kagent"))
parser.add_argument("--url", default=os.environ.get("CONTROLLER_URL", "http://127.0.0.1:18083"))
parser.add_argument("--session", default="", help="reuse a kagent session id instead of creating one")
parser.add_argument("--approve", action="store_true", help="answer permission requests with allow-once")
parser.add_argument("--capture", default="", help="capture name under captures/ (raw frames as .jsonl)")
parser.add_argument("--timeout", type=int, default=int(os.environ.get("ACP_TIMEOUT", "420")))
parser.add_argument("--quiet", action="store_true", help="print only the final agent text")
args = parser.parse_args()

captures_dir = os.environ.get("CAPTURES", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "captures"))
capture_file = None
if args.capture:
    os.makedirs(captures_dir, exist_ok=True)
    capture_file = open(os.path.join(captures_dir, args.capture + ".jsonl"), "w", encoding="utf-8")

def say(*parts):
    if not args.quiet:
        print(*parts, flush=True)

def record(direction, obj):
    if capture_file:
        capture_file.write(json.dumps({"t": round(time.time(), 3), "dir": direction, "msg": obj}) + "\n")
        capture_file.flush()

# 1. a kagent session, exactly as the UI creates one
session_id = args.session
if not session_id:
    req = urllib.request.Request(
        args.url + "/api/sessions",
        data=json.dumps({"agent_ref": f"{args.namespace}/{args.agent}", "name": "lab"}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as response:
        session_id = json.load(response)["data"]["id"]
say(f"kagent session: {session_id}")

# 2. the per-session ACP WebSocket
host, port = args.url.split("//", 1)[1].split(":")
path = f"/api/agentharnesses/{args.namespace}/{args.agent}/acp/{session_id}"
deadline = time.time() + args.timeout
sock = socket.create_connection((host, int(port)), timeout=args.timeout)
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(65536)
    if not chunk:
        break
    buf += chunk
status_line, _, rest = buf.partition(b"\r\n\r\n")
if b" 101 " not in status_line.split(b"\r\n")[0]:
    sys.stderr.write("ACP handshake failed: " + status_line.decode(errors="replace") + rest.decode(errors="replace") + "\n")
    sys.exit(2)
say(f"ACP websocket: {path}")

def send(obj):
    record("out", obj)
    payload = json.dumps(obj).encode()
    header = bytearray([0x81])
    n, mask = len(payload), os.urandom(4)
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126); header += struct.pack(">H", n)
    else:
        header.append(0x80 | 127); header += struct.pack(">Q", n)
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def frames():
    global rest
    while time.time() < deadline:
        while len(rest) < 2:
            sock.settimeout(max(1, deadline - time.time()))
            data = sock.recv(65536)
            if not data:
                return
            rest += data
        op = rest[0] & 0x0F
        length = rest[1] & 0x7F
        offset = 2
        if length == 126:
            length = struct.unpack(">H", rest[2:4])[0]; offset = 4
        elif length == 127:
            length = struct.unpack(">Q", rest[2:10])[0]; offset = 10
        while len(rest) < offset + length:
            data = sock.recv(65536)
            if not data:
                return
            rest += data
        payload, rest = rest[offset:offset + length], rest[offset + length:]
        if op == 8:
            return
        if op in (1, 2):
            try:
                yield json.loads(payload)
            except ValueError:
                pass

final_text = []
tool_calls = {}
exit_code = 0
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}}})
try:
    for msg in frames():
        record("in", msg)
        method = msg.get("method", "")
        if msg.get("id") == 1 and "result" in msg:
            agent = msg["result"].get("agentInfo") or msg["result"].get("agentCapabilities") or {}
            say("initialize:", json.dumps(msg["result"])[:200])
            send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/workspace", "mcpServers": []}})
        elif msg.get("id") == 2 and "result" in msg:
            acp_session = msg["result"]["sessionId"]
            say(f"ACP session: {acp_session}")
            send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                  "params": {"sessionId": acp_session, "prompt": [{"type": "text", "text": args.prompt}]}})
            say(f"> {args.prompt}")
        elif method == "session/update":
            update = msg.get("params", {}).get("update", {})
            kind = update.get("sessionUpdate", "")
            if kind == "agent_message_chunk":
                text = (update.get("content") or {}).get("text", "")
                if text:
                    final_text.append(text)
            elif kind == "tool_call":
                tool_calls[update.get("toolCallId")] = update.get("title", "")
                say(f"  [tool_call] {update.get('kind', '')}: {update.get('title', '')}")
            elif kind == "tool_call_update":
                status = update.get("status", "")
                if status in ("completed", "failed"):
                    say(f"  [tool_call_update] {status}: {tool_calls.get(update.get('toolCallId'), update.get('toolCallId'))}")
            elif kind == "agent_thought_chunk":
                pass
            elif kind:
                say(f"  [{kind}]")
        elif method == "session/request_permission":
            params = msg.get("params", {})
            call = params.get("toolCall", {})
            options = params.get("options", [])
            say(f"  [request_permission] {call.get('title', '')}  options={[o.get('kind') for o in options]}")
            chosen = None
            if args.approve:
                for wanted in ("allow_once", "allow_always"):
                    chosen = next((o for o in options if o.get("kind") == wanted), None)
                    if chosen:
                        break
            if chosen:
                say(f"  [permission] -> {chosen.get('kind')} ({chosen.get('name', '')})")
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "selected", "optionId": chosen["optionId"]}}})
            else:
                say("  [permission] -> cancelled (run with --approve to allow)")
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "cancelled"}}})
        elif msg.get("id") == 3:
            if "error" in msg:
                sys.stderr.write("prompt error: " + json.dumps(msg["error"]) + "\n")
                exit_code = 1
            else:
                say(f"stopReason: {msg['result'].get('stopReason')}")
            break
        elif "error" in msg:
            sys.stderr.write("ACP error: " + json.dumps(msg["error"]) + "\n")
            exit_code = 1
            break
    else:
        sys.stderr.write("ACP prompt did not complete before the deadline\n")
        exit_code = 3
finally:
    try:
        sock.close()
    except OSError:
        pass
    if capture_file:
        capture_file.close()

text = "".join(final_text).strip()
print(("" if args.quiet else "\n") + text)
sys.exit(exit_code)
