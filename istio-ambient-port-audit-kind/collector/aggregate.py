#!/usr/bin/env python3
"""aggregate.py - runs as a CronJob, once a minute.

Merges every node's observations from the report ConfigMap, reads the
CONFIGURED surface (Service ports + AuthorizationPolicy allowed ports), and
writes the diff to the report.json key of the same ConfigMap: per service,
what is exposed, what is allowed, what is actually used, what is not, and
what got denied.

Same image and same stdlib-only style as collector.py; the two scripts are
the whole audit.
"""

import json
import os
import ssl
import time
import urllib.request

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

NS_APP = os.environ.get("NS_APP", "port-audit")
NS_AUDIT = os.environ.get("NS_AUDIT", "port-audit-system")
CM = os.environ.get("REPORT_CM", "port-audit-report")

SSL_CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def request(method, path, body=None, content_type="application/json"):
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as resp:
        return json.load(resp)


def union(maps):
    """Merge a list of {key: [ports]} maps into one, unioning the port lists."""
    merged = {}
    for mapping in maps:
        for key, ports in mapping.items():
            merged[key] = sorted(set(merged.get(key, [])) | set(ports))
    return merged


def allowed_ports(policies, app):
    """Ports named by ALLOW AuthorizationPolicies whose selector matches this
    app label (the labelling convention this lab uses throughout)."""
    ports = set()
    for policy in policies:
        spec = policy.get("spec", {})
        if spec.get("action", "ALLOW") != "ALLOW":
            continue
        selector = spec.get("selector", {}).get("matchLabels", {})
        if selector.get("app") != app:
            continue
        for rule in spec.get("rules", []):
            for to in rule.get("to", []):
                for port in to.get("operation", {}).get("ports", []):
                    ports.add(int(port))
    return sorted(ports)


def main():
    cm = request("GET", f"/api/v1/namespaces/{NS_AUDIT}/configmaps/{CM}")
    nodes = [json.loads(value) for key, value in (cm.get("data") or {}).items()
             if key != "report.json"]
    services = request("GET", f"/api/v1/namespaces/{NS_APP}/services")["items"]
    policies = request(
        "GET", f"/apis/security.istio.io/v1/namespaces/{NS_APP}/authorizationpolicies"
    )["items"]

    observed = union(n.get("services", {}) for n in nodes)
    observed_pods = union(n.get("pods", {}) for n in nodes)
    denied = union(n.get("denied", {}) for n in nodes)

    rows = []
    for svc in services:
        name = svc["metadata"]["name"]
        fqdn = f"{name}.{svc['metadata']['namespace']}.svc.cluster.local"
        configured = sorted(p["port"] for p in svc["spec"].get("ports", []))
        allowed = allowed_ports(policies, svc["spec"].get("selector", {}).get("app"))
        used = observed.get(fqdn, [])
        rows.append({
            "service": name,
            "configured_service_ports": configured,
            "authz_allowed_ports": allowed,
            "used_ports": used,
            "unused_ports": [p for p in configured if p not in used],
            "authz_allowed_never_used": [p for p in allowed if p not in used],
            "denied_attempts": denied.get(fqdn, []),
            "over_provisioned": any(p not in used for p in configured),
        })

    report = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nodes_reporting": [n["node"] for n in nodes if "node" in n],
        "services": rows,
        "pods": observed_pods,
    }
    body = json.dumps({"data": {"report.json": json.dumps(report, indent=2)}}).encode()
    request("PATCH", f"/api/v1/namespaces/{NS_AUDIT}/configmaps/{CM}",
            body=body, content_type="application/merge-patch+json")
    print("report.json updated:")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
