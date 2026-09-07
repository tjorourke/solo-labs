#!/usr/bin/env python3
"""Talk to a kagent AgentHarness over the Agent Client Protocol.

A harness does not answer on A2A like an ordinary Agent: it speaks ACP (JSON-RPC) over a
websocket the controller exposes per session, so this is a minimal RFC6455 client with no
dependencies beyond the standard library. The flow is initialize -> session/new ->
session/prompt, and replies stream back as session/update notifications.

  ACP_PORT=19110 python3 acp-chat.py /api/agentharnesses/<ns>/<name>/acp/<sessionId> "prompt"
"""
import base64, json, os, socket, struct, sys, time

HOST, PORT = "127.0.0.1", int(os.environ.get("ACP_PORT", "18099"))
PATH = sys.argv[1]
PROMPT = sys.argv[2] if len(sys.argv) > 2 else "Say hello in five words."
DEADLINE = time.time() + float(os.environ.get("ACP_TIMEOUT", "180"))

s = socket.create_connection((HOST, PORT), timeout=20)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET {PATH} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
if b"101" not in buf.split(b"\r\n")[0]:
    print("handshake failed:", buf.split(b"\r\n")[0]); sys.exit(1)
rest = buf.split(b"\r\n\r\n", 1)[1]

def send(obj):
    p = json.dumps(obj).encode()
    hdr = bytearray([0x81])
    n, mask = len(p), os.urandom(4)
    if n < 126: hdr.append(0x80 | n)
    elif n < 65536: hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else: hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))

def frames():
    global rest
    while time.time() < DEADLINE:
        while len(rest) < 2:
            s.settimeout(max(1, DEADLINE - time.time()))
            try: d = s.recv(65536)
            except socket.timeout: return
            if not d: return
            rest += d
        op = rest[0] & 0x0F; ln = rest[1] & 0x7F; off = 2
        if ln == 126: ln = struct.unpack(">H", rest[2:4])[0]; off = 4
        elif ln == 127: ln = struct.unpack(">Q", rest[2:10])[0]; off = 10
        while len(rest) < off + ln:
            try: d = s.recv(65536)
            except socket.timeout: return
            if not d: return
            rest += d
        payload, rest = rest[off:off+ln], rest[off+ln:]
        if op == 8: return
        if op in (1, 2):
            try: yield json.loads(payload)
            except Exception: pass

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}}})
sent_prompt = False
for msg in frames():
    line = json.dumps(msg)
    if msg.get("id") == 1 and "result" in msg:
        print("initialize OK:", line[:160])
        send({"jsonrpc": "2.0", "id": 2, "method": "session/new",
              "params": {"cwd": "/workspace", "mcpServers": []}})
        continue
    if msg.get("id") == 2 and "result" in msg and not sent_prompt:
        sid = msg["result"].get("sessionId", "")
        print("ACP session:", sid)
        send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
              "params": {"sessionId": sid, "prompt": [{"type": "text", "text": PROMPT}]}})
        sent_prompt = True
        print("prompt sent:", PROMPT)
        continue
    m = msg.get("method", "")
    if m == "session/update":
        u = msg.get("params", {}).get("update", {})
        c = u.get("content") or {}
        txt = c.get("text") if isinstance(c, dict) else None
        if txt: print("AGENT:", txt.strip()[:400])
    elif msg.get("id") == 3:
        print("prompt result:", line[:300]); break
    elif "error" in msg:
        print("ERROR:", line[:300]); break
