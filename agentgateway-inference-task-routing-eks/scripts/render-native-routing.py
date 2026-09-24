#!/usr/bin/env python3
"""Render the native decision policy from the shared routing data and CEL source.

The rendered templates are checked in for the Manifests page and OSS mirror.
JWKS substitution remains the install script's job. --check never writes files.
"""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def decision_expression(data=None):
    if data is None:
        data = json.loads((ROOT / "opa/routing-data.json").read_text())
    return (ROOT / "native/decision.cel").read_text().replace(
        "__DATA__", json.dumps(data, separators=(",", ":")))


def apply_data(data, context, namespace="agentgateway-system"):
    """Update only native routing metadata; retain live JWKS, tracing and overlays."""
    kube = ["kubectl", "--context", context, "-n", namespace]
    current = subprocess.run(kube + ["get", "enterpriseagentgatewaypolicy", "decide", "-o", "json"],
                             text=True, capture_output=True, check=True)
    policy = json.loads(current.stdout)
    patch = [
        {"op": "test", "path": "/metadata/resourceVersion", "value": policy["metadata"]["resourceVersion"]},
        {"op": "replace", "path": "/spec/traffic/transformation/request/metadata/routing", "value": decision_expression(data)},
    ]
    subprocess.run(kube + ["patch", "enterpriseagentgatewaypolicy", "decide", "--type=json", "-p", json.dumps(patch)],
                   text=True, capture_output=True, check=True)


def policies(edition="enterprise", data=None):
    group = "enterpriseagentgateway.solo.io" if edition == "enterprise" else "agentgateway.dev"
    kind = "EnterpriseAgentgatewayPolicy" if edition == "enterprise" else "AgentgatewayPolicy"
    target = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "decision-gateway"}

    def policy(name, traffic):
        return {"apiVersion": group + "/v1alpha1", "kind": kind,
                "metadata": {"name": name, "namespace": "agentgateway-system"},
                "spec": {"targetRefs": [target], "traffic": traffic}}

    # A failed metadata expression is not a decision. All routing fields are
    # overwritten (null removes a supplied header); the post-routing gate requires
    # in-process metadata, which cannot be injected by a client.
    fields = {"x-model-pool": 'metadata.routing.status == 200 ? metadata.routing.pool : "denied"',
              "x-model-class": "metadata.routing.class",
              "x-routing-reason": "metadata.routing.reason",
              "x-routing-user": "metadata.routing.user",
              "x-kernwerk-lane": 'metadata.routing.lane != "" ? metadata.routing.lane : null',
              "x-agw-routing-decision": "toJson(metadata.routing)"}
    pre = policy("decide", {
        "phase": "PreRouting",
        "jwtAuthentication": {"mode": "Strict", "providers": [
            {"issuer": "https://identity.lab", "audiences": ["model-gateway"], "jwks": {"inline": "__JWKS__"}},
            {"issuer": "agentdesktop-controller", "audiences": ["model-gateway"], "jwks": {"inline": "__AD_JWKS__"}},
        ]},
        "transformation": {
            "request": {"metadata": {"routing": decision_expression(data), "routing_body": "string(request.body)"},
                        "set": [{"name": k, "value": v} for k, v in fields.items()]},
            "response": {"set": [{"name": name, "value": expr} for name, expr in {
                "x-model-pool": "metadata.routing.status == 200 ? metadata.routing.pool : null",
                "x-model-class": "metadata.routing.status == 200 ? metadata.routing.class : null",
                "x-routing-reason": "metadata.routing.status != 403 ? metadata.routing.reason : null",
            }.items()]},
        },
    })
    # Also record the native result at completion. A budget may refuse before
    # PostRouting extAuth runs; this preserves those cards as well as audit ones.
    pre["spec"]["frontend"] = {"accessLog": {"attributes": {"add": [
        {"name": "routing.decision", "expression": "toJson(metadata.routing)"},
        {"name": "routing.body", "expression": "metadata.routing_body"},
    ]}}}
    if edition == "enterprise":
        pre["spec"]["frontend"]["tracing"] = {
            "backendRef": {"name": "solo-enterprise-telemetry-collector", "namespace": "agentgateway-system", "port": 4317},
            "protocol": "GRPC", "randomSampling": "true"}

    post = policy("routing-outcome", {
        # The audit adapter records an immediate event for the existing live
        # console. It always allows; AGW alone enforces the decision below.
        "extAuth": {"backendRef": {"name": "routing-audit", "namespace": "agentgateway-system", "port": 9191},
                    "grpc": {}, "forwardBody": {"maxSize": "8Mi"}, "failureMode": "FailClosed"},
        "directResponse": {"conditional": [
            {"condition": '!has(metadata.routing) || !(metadata.routing.status in [200, 422])',
             "policy": {"status": 403, "headers": [{"name": "content-type", "value": "application/json"}],
                        "body": '{"error":{"type":"forbidden","message":"no suitable permitted backend for this task"}}'}},
            {"condition": 'metadata.routing.status == 422',
             "policy": {"status": 422, "headers": [{"name": "content-type", "value": "application/json"}],
                        "bodyExpression": 'toJson({"error": {"type": "blocked", "message": metadata.routing.error, "param": null, "code": null}})'}},
        ]},
        "transformation": {"request": {"remove": ["x-agw-routing-decision"]}},
    })
    return pre, post


def main():
    import yaml
    class Dumper(yaml.SafeDumper):
        pass
    def represent_string(dumper, value):
        # The install script substitutes raw JSON into these placeholders. They
        # must remain single-quoted YAML strings, not turn into inline YAML maps.
        style = "'" if value in ("__JWKS__", "__AD_JWKS__") else "|" if "\n" in value else None
        return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)
    Dumper.add_representer(str, represent_string)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for edition, folder in [("enterprise", "yaml"), ("oss", "yaml-oss")]:
        for policy, filename in zip(policies(edition), ["50-decide-policy.yaml.tmpl", "51-routing-outcome.yaml"]):
            text = "# Generated by scripts/render-native-routing.py. Edit native/decision.cel or opa/routing-data.json.\n"
            text += yaml.dump(policy, Dumper=Dumper, sort_keys=False, width=100)
            path = ROOT / folder / filename
            if args.check:
                if path.read_text() != text:
                    raise SystemExit(f"out of date: {path}")
            else:
                path.write_text(text)


if __name__ == "__main__":
    main()
