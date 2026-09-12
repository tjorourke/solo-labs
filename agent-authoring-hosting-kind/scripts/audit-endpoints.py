#!/usr/bin/env python3
"""Report the outcome of a specific unauthenticated MCP initialize probe.

This inventories Gateway-attached HTTPRoutes, not every exposure mechanism.
It does not infer authentication from backend kind or from a failed connection.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import re
import subprocess

INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-03-26", "capabilities": {},
    "clientInfo": {"name": "endpoint-audit", "version": "1"}}})


def classify(code, body, returncode=0):
    if returncode:
        return "INCONCLUSIVE", "connection, DNS, TLS or timeout error"
    if code in (401, 403):
        return "DENIED", f"HTTP {code}; this request was rejected"
    if code == 200:
        candidates = [body] + [line[5:].strip() for line in body.splitlines()
                               if line.startswith("data:")]
        for candidate in candidates:
            try:
                reply = json.loads(candidate)
            except ValueError:
                continue
            if not isinstance(reply, dict) or reply.get("error"):
                continue
            result = reply.get("result")
            if (isinstance(result, dict) and isinstance(result.get("protocolVersion"), str)
                    and isinstance(result.get("serverInfo"), dict)
                    and isinstance(result["serverInfo"].get("name"), str)):
                return "ACCEPTED", "HTTP 200; MCP initialize succeeded without credentials"
        return "INCONCLUSIVE", "HTTP 200 without a recognised MCP initialize result"
    return "INCONCLUSIVE", f"HTTP {code}; does not establish authentication"


def route_targets(routes, gateways, path):
    gateways = {(g["metadata"]["namespace"], g["metadata"]["name"]): g for g in gateways}
    for route in routes:
        ns, name = route["metadata"]["namespace"], route["metadata"]["name"]
        spec = route["spec"]
        kinds = {ref.get("kind", "Service") for rule in spec.get("rules", [])
                 for ref in rule.get("backendRefs", [])}
        for parent in spec.get("parentRefs", []):
            if parent.get("kind", "Gateway") != "Gateway":
                continue
            gateway = gateways.get((parent.get("namespace", ns), parent["name"]))
            listeners = gateway.get("spec", {}).get("listeners", []) if gateway else []
            listeners = [listener for listener in listeners
                         if (not parent.get("sectionName") or listener["name"] == parent["sectionName"])
                         and (not parent.get("port") or listener["port"] == parent["port"])]
            for host in spec.get("hostnames") or ["(any host)"]:
                base = {"route": f"{ns}/{name}", "host": host, "url": None,
                        "gateway": f'{parent.get("namespace", ns)}/{parent["name"]}'}
                reason = None
                if not kinds or any("AgentgatewayBackend" not in kind for kind in kinds):
                    reason = "backend type not covered; authentication not tested"
                elif not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", host):
                    reason = "no concrete hostname; supply and test an appropriate Host name separately"
                elif host.endswith(".svc.cluster.local"):
                    reason = "cluster-local hostname; not probed from this workstation"
                elif not listeners:
                    reason = "Gateway or selected listener not found"
                if reason:
                    yield dict(base, status="NOT_TESTED", detail=reason)
                    continue
                for listener in listeners:
                    item = dict(base, listener=listener["name"])
                    protocol = listener.get("protocol")
                    if protocol not in ("HTTP", "HTTPS"):
                        yield dict(item, status="NOT_TESTED", detail=f"unsupported listener protocol {protocol}")
                        continue
                    scheme = protocol.lower()
                    port = listener["port"]
                    authority = host if (scheme, port) in (("http", 80), ("https", 443)) else f"{host}:{port}"
                    yield dict(item, url=f"{scheme}://{authority}{path}")


def probe(item):
    if not item["url"]:
        return item
    try:
        response = subprocess.run([
            "curl", "-q", "-sS", "--max-time", "8", "--max-filesize", "1048576",
            "-w", "\n%{http_code}", "-X", "POST", item["url"],
            "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream",
            "-d", INIT], capture_output=True, text=True, timeout=12)
        body, _, code = response.stdout.rpartition("\n")
        status, detail = classify(int(code) if code.isdigit() else 0, body, response.returncode)
    except subprocess.TimeoutExpired:
        status, detail = "INCONCLUSIVE", "probe process timed out"
    return dict(item, status=status, detail=detail)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", default="kagent")
    parser.add_argument("--path", default="/mcp", help="One path to probe; other paths remain untested")
    parser.add_argument("--json", action="store_true", help="Machine-readable report")
    args = parser.parse_args()
    if not args.path.startswith("/") or any(c in args.path for c in "\r\n"):
        parser.error("--path must be an absolute HTTP path")

    def get(resource, *scope):
        return json.loads(subprocess.check_output([
            "kubectl", "--context", args.context, "get", resource, *scope, "-o", "json"], text=True))["items"]

    gateways = get("gateway", "-A")
    routes = get("httproute", "-A")
    services = get("service", "-n", args.namespace)
    targets = list(route_targets(routes, gateways, args.path))
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(probe, targets))
    report = {
        "scope": f"Unauthenticated MCP initialize at {args.path}; Gateway-attached HTTPRoutes only",
        "waypoints": [f'{g["metadata"]["namespace"]}/{g["metadata"]["name"]}' for g in gateways
                      if "waypoint" in g["spec"].get("gatewayClassName", "")],
        "nonClusterIPServices": [{"name": s["metadata"]["name"], "type": s["spec"].get("type", "ClusterIP")}
                                 for s in services if s["spec"].get("type", "ClusterIP") != "ClusterIP"],
        "results": results, "counts": dict(Counter(r["status"] for r in results)),
    }
    if args.json:
        print(json.dumps(report, indent=2))
        return
    print(report["scope"])
    print("\nWaypoint inventory (not an exposure verdict):")
    for waypoint in report["waypoints"]:
        print(" ", waypoint)
    print(f"\nNon-ClusterIP Services in {args.namespace} (exposure requires review):")
    for service in report["nonClusterIPServices"]:
        print(f'  {service["name"]}: {service["type"]}')
    if not report["nonClusterIPServices"]:
        print("  none")
    print("\nRoute probes:")
    for item in results:
        print(f'  {item["status"]:12} {item["route"]} {item["url"] or item["host"]}: {item["detail"]}')
    print("\nSummary:", ", ".join(f"{key}={report['counts'].get(key, 0)}" for key in
                                   ("ACCEPTED", "DENIED", "INCONCLUSIVE", "NOT_TESTED")))
    print("ACCEPTED covers initialize only; tool authorisation still needs testing.")
    print("Skipped routes and inconclusive probes are not evidence of protection. Findings do not change the exit code.")


if __name__ == "__main__":
    main()
