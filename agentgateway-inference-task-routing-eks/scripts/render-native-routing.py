#!/usr/bin/env python3
"""Render the native JWT, shaping and enforcement policies for the hybrid router.

The rendered templates are checked in for the Manifests page and OSS mirror.
JWKS substitution remains the install script's job. --check never writes files.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def policies(edition="enterprise"):
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
               "x-kernwerk-lane": 'metadata.routing.lane != "" ? metadata.routing.lane : null'}
    pre = policy("decide", {
        "phase": "PreRouting",
        "jwtAuthentication": {"mode": "Strict", "providers": [
            {"issuer": "https://identity.lab", "audiences": ["model-gateway"], "jwks": {"inline": "__JWKS__"}},
            {"issuer": "agentdesktop-controller", "audiences": ["model-gateway"], "jwks": {"inline": "__AD_JWKS__"}},
        ]},
        "extAuth": {"backendRef": {"name": "routing-policy", "namespace": "agentgateway-system", "port": 9191},
                    "grpc": {}, "forwardBody": {"maxSize": "8Mi"}, "failureMode": "FailClosed"},
        "transformation": {
            "request": {"metadata": {"routing": "extauthz.routing", "routing_body": "string(request.body)"},
                        "set": [{"name": k, "value": v} for k, v in fields.items()]},
            "response": {"set": [{"name": name, "value": expr} for name, expr in {
                "x-model-pool": "metadata.routing.status == 200 ? metadata.routing.pool : null",
                "x-model-class": "metadata.routing.status == 200 ? metadata.routing.class : null",
                "x-routing-reason": "metadata.routing.status != 403 ? metadata.routing.reason : null",
            }.items()]},
        },
    })
    # Retain the decision at completion, including requests refused by a budget.
    pre["spec"]["frontend"] = {"accessLog": {"attributes": {"add": [
        {"name": "routing.decision", "expression": "toJson(metadata.routing)"},
        {"name": "routing.body", "expression": "metadata.routing_body"},
    ]}}}
    if edition == "enterprise":
        pre["spec"]["frontend"]["tracing"] = {
            "backendRef": {"name": "solo-enterprise-telemetry-collector", "namespace": "agentgateway-system", "port": 4317},
            "protocol": "GRPC", "randomSampling": "true"}

    post = policy("routing-outcome", {
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


def annotate_policy(text, name):
    """Keep the walkthrough comments in both generated editions of the CRD."""
    if name == "decide":
        notes = {
            "  targetRefs:": "Attach to decision-gateway, so these checks run for its requests.",
            "    phase: PreRouting": "Make the decision before AGW selects an HTTPRoute.",
            "    jwtAuthentication:": "Verify the signature, issuer and audience before forwarding claims to Rego.",
            "    extAuth:": "Rego evaluates group permissions and data rules. An unavailable service fails closed.",
            "          routing:": "Copy the trusted extAuth result. No users, permissions or decision programme live here.",
            "          routing_body:": "Keep the original body for the decision dashboard.",
            "        set:": "Overwrite caller-supplied routing headers with the trusted decision.",
            "      response:": "Return the pool, model class and reason to the client where applicable.",
            "  frontend:": "Record the decision even when a later budget check refuses the request.",
        }
    else:
        notes = {
            "    directResponse:": "After route selection, enforce the saved decision before any model call.",
            "      - condition:": "Missing metadata or no permitted route returns 403; a blocked prompt returns 422.",
            "    transformation:": "Remove the audit-only header before forwarding an allowed request.",
        }
    lines = []
    for line in text.splitlines():
        for prefix in list(notes):
            if line.startswith(prefix):
                indent = line[:len(line) - len(line.lstrip())]
                lines.append(indent + "# " + notes.pop(prefix))
                break
        lines.append(line)
    if notes:
        raise ValueError(f"annotation fields missing from {name}: {list(notes)}")
    return "\n".join(lines) + "\n"


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
            text = "# Generated by scripts/render-native-routing.py. Business rules live in opa/routing.rego.\n"
            text += annotate_policy(yaml.dump(policy, Dumper=Dumper, sort_keys=False, width=100),
                                    policy["metadata"]["name"])
            path = ROOT / folder / filename
            if args.check:
                if path.read_text() != text:
                    raise SystemExit(f"out of date: {path}")
            else:
                path.write_text(text)


if __name__ == "__main__":
    main()
