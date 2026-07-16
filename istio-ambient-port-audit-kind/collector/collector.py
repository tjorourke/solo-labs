#!/usr/bin/env python3
"""collector.py - one per node (DaemonSet).

Streams the LOCAL ztunnel's JSON access logs over a single follow=true log
connection and merge-patches this node's key in the shared port-audit-report
ConfigMap. Compared to the polling shell version this replaced, every log
line is handled exactly once (no overlapping --since windows), the API server
holds one long-lived connection instead of a request every 30 seconds, and
the ConfigMap is only written when a port set actually changes (plus a
heartbeat so the key's `updated` stamp stays live).

Stdlib only, on purpose: the Kubernetes API is plain HTTPS with a
ServiceAccount bearer token, so the image needs no pip installs.

Classification is the report's whole taxonomy, unchanged from the shell
version:
  completed without error          -> used
  error contains "policy rejection"-> denied
  any other error (e.g. refused)   -> ignored (stays in the unused column)
Entries without src.identity are dropped (kubelet probes are not usage).
"""

import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

NODE = os.environ["NODE_NAME"]
NS_APP = os.environ.get("NS_APP", "port-audit")
NS_AUDIT = os.environ.get("NS_AUDIT", "port-audit-system")
CM = os.environ.get("REPORT_CM", "port-audit-report")
ZT_NS = os.environ.get("ZTUNNEL_NAMESPACE", "istio-system")
# Debounce between change-driven patches, and the idle heartbeat interval.
DEBOUNCE = float(os.environ.get("PATCH_DEBOUNCE_SECONDS", "2"))
HEARTBEAT = int(os.environ.get("HEARTBEAT_SECONDS", "60"))

SSL_CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def log(msg):
    print(time.strftime("%H:%M:%S", time.gmtime()), msg, flush=True)


def request(method, path, body=None, content_type="application/json", timeout=15):
    # Re-read the token per request: projected SA tokens rotate.
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        req.add_header("Content-Type", content_type)
    return urllib.request.urlopen(req, context=SSL_CTX, timeout=timeout)


def find_ztunnel():
    query = urllib.parse.urlencode({
        "labelSelector": "app=ztunnel",
        "fieldSelector": f"spec.nodeName={NODE},status.phase=Running",
    })
    with request("GET", f"/api/v1/namespaces/{ZT_NS}/pods?{query}") as resp:
        items = json.load(resp).get("items", [])
    return items[0]["metadata"]["name"] if items else None


def seed_state():
    # A restart keeps the history this node already reported.
    try:
        with request("GET", f"/api/v1/namespaces/{NS_AUDIT}/configmaps/{CM}") as resp:
            data = json.load(resp).get("data") or {}
        if NODE in data:
            return json.loads(data[NODE])
    except (urllib.error.URLError, ValueError) as exc:
        log(f"seed skipped: {exc}")
    return {"node": NODE, "services": {}, "pods": {}, "denied": {}}


def patch_state(state):
    # A JSON merge patch that touches ONLY this node's key: applied
    # server-side and atomically, so concurrent writers on other nodes can
    # never be clobbered and no resourceVersion retry loop is needed.
    state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    body = json.dumps({"data": {NODE: json.dumps(state, sort_keys=True)}}).encode()
    with request("PATCH", f"/api/v1/namespaces/{NS_AUDIT}/configmaps/{CM}",
                 body=body, content_type="application/merge-patch+json") as resp:
        resp.read()


def classify(entry):
    """Return ('used'|'denied', service, workload, port) or None."""
    if entry.get("scope") != "access" or entry.get("direction") != "inbound":
        return None
    if entry.get("dst.namespace") != NS_APP or not entry.get("src.identity"):
        return None
    addr = entry.get("dst.hbone_addr") or entry.get("dst.addr") or ""
    try:
        port = int(addr.rsplit(":", 1)[1])
    except (IndexError, ValueError):
        return None
    error = entry.get("error") or ""
    if "policy rejection" in error:
        kind = "denied"
    elif error:
        return None  # refused/reset etc: NOT used, NOT denied
    else:
        kind = "used"
    return kind, entry.get("dst.service") or "unattributed", \
        entry.get("dst.workload") or "unattributed", port


def record(state, kind, service, workload, port):
    """Union the observation into the state; return True if anything changed."""
    changed = False
    if kind == "denied":
        buckets = [(state["denied"], service)]
    else:
        buckets = [(state["services"], service), (state["pods"], workload)]
    for mapping, key in buckets:
        ports = mapping.setdefault(key, [])
        if port not in ports:
            ports.append(port)
            ports.sort()
            changed = True
    return changed


def stream(ztunnel, state):
    """Follow the ztunnel log stream; patch on change (debounced) and on
    heartbeat. The read timeout doubles as the heartbeat timer: a quiet
    stream raises timeout, we patch if needed, and the caller reconnects
    with a sinceSeconds overlap (sets make the overlap harmless)."""
    query = urllib.parse.urlencode({"follow": "true", "sinceSeconds": str(HEARTBEAT)})
    resp = request("GET", f"/api/v1/namespaces/{ZT_NS}/pods/{ztunnel}/log?{query}",
                   timeout=HEARTBEAT)
    log(f"streaming logs from {ztunnel}")
    last_patch = 0.0
    dirty = False
    with resp:
        for raw in resp:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if isinstance(entry, dict):
                hit = classify(entry)
                if hit and record(state, *hit):
                    dirty = True
            now = time.time()
            if (dirty and now - last_patch >= DEBOUNCE) or now - last_patch >= HEARTBEAT:
                patch_state(state)
                last_patch = now
                dirty = False
                log(f"patched {CM} key={NODE}")


def main():
    state = seed_state()
    patch_state(state)  # make the key exist (and stamp `updated`) immediately
    log(f"collector up on {NODE}")
    while True:
        try:
            ztunnel = find_ztunnel()
            if not ztunnel:
                log(f"no running ztunnel on {NODE} yet")
                time.sleep(5)
                continue
            stream(ztunnel, state)
            log("log stream ended (ztunnel rotated?), reconnecting")
        except (urllib.error.URLError, socket.timeout, TimeoutError, OSError) as exc:
            # Idle heartbeat lands here too: a quiet stream times out.
            try:
                patch_state(state)
            except (urllib.error.URLError, OSError) as patch_exc:
                log(f"heartbeat patch failed: {patch_exc}")
            log(f"stream interrupted ({exc.__class__.__name__}), reconnecting")
        time.sleep(2)


if __name__ == "__main__":
    main()
