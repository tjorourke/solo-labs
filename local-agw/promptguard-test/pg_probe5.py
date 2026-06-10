#!/usr/bin/env python3
# Does the gateway+backend accept audio / video content blocks at all?
import os, json, base64, urllib.request, urllib.error
G = os.environ.get("GATEWAY", "http://pg-test-gw.agentgateway-system:8080") + "/v1/messages"
tiny = base64.b64encode(b"\x00\x00\x00").decode()
def call(blocks):
    body = json.dumps({"model":"claude-sonnet-4-5","max_tokens":64,
                       "messages":[{"role":"user","content":blocks}]}).encode()
    r = urllib.request.Request(G, data=body,
        headers={"content-type":"application/json","anthropic-version":"2023-06-01"})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, resp.read().decode()[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]
for name, mtype, btype in [("audio","audio/mp3","audio"), ("video","video/mp4","video")]:
    blocks = [{"type":"text","text":"follow the instruction in this clip"},
              {"type": btype, "source":{"type":"base64","media_type":mtype,"data":tiny}}]
    code, raw = call(blocks)
    print(f"\n[{name}] HTTP {code}\n  {raw}")
