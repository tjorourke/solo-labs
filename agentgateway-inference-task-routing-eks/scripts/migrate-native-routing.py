#!/usr/bin/env python3
"""Migrate an existing Enterprise demo to hybrid, group-based routing.

Use --backup PATH --context CONTEXT to apply, or --restore PATH --context CONTEXT
to restore the exact policies saved before migration. No secrets or signing keys
are read. Prepare group-bearing tokens and refresh Agentdesktop enrolments first.
The original OPA and audit deployments stay available for rollback/Part 3.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("renderer", ROOT / "scripts/render-native-routing.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def clean(obj):
    obj.pop("status", None)
    for field in ["uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"]:
        obj["metadata"].pop(field, None)
    obj["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
    return obj


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--backup", type=Path)
    group.add_argument("--restore", type=Path)
    args = parser.parse_args()
    kube = ["kubectl", "--context", args.context, "-n", "agentgateway-system"]

    def run(*parts, **kwargs):
        return subprocess.run(kube + list(parts), text=True, check=True, **kwargs)

    def get(kind, name, optional=False):
        proc = subprocess.run(kube + ["get", kind, name, "-o", "json", "--ignore-not-found"],
                              text=True, capture_output=True, check=True)
        if not proc.stdout.strip():
            if optional:
                return None
            raise RuntimeError(f"missing {kind}/{name}")
        return json.loads(proc.stdout)

    if args.restore:
        backup = json.loads(args.restore.read_text())
        if backup["context"] != args.context:
            raise SystemExit("Rollback context does not match the snapshot")
        run("apply", "-f", "-", input=yaml.safe_dump_all(backup["objects"]))
        for item in backup["created"]:
            run("delete", item["kind"], item["name"], "--ignore-not-found")
        return
    if args.backup.exists():
        raise SystemExit("Refusing to overwrite an existing rollback snapshot")

    old = get("EnterpriseAgentgatewayPolicy", "decide")
    pre, post = renderer.policies()
    pre["spec"]["traffic"]["jwtAuthentication"] = old["spec"]["traffic"]["jwtAuthentication"]
    # Keep any live telemetry configuration while adding the native audit fields.
    native_log = pre["spec"]["frontend"]["accessLog"]["attributes"]["add"]
    pre["spec"]["frontend"] = old["spec"].get("frontend", {})
    attributes = pre["spec"]["frontend"].setdefault("accessLog", {}).setdefault("attributes", {})
    attributes["add"] = [item for item in attributes.get("add", []) if item["name"] not in {"routing.decision", "routing.body"}] + native_log
    setup = list(yaml.safe_load_all((ROOT / "yaml/20-opa.yaml").read_text()))
    setup.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "routing-policy-code", "namespace": "agentgateway-system"},
                  "data": {"routing.rego": (ROOT / "opa/routing.rego").read_text()}})
    setup.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "routing-policy-data", "namespace": "agentgateway-system"},
                  "data": {"routing-data.json": (ROOT / "opa/routing-data.json").read_text()}})
    denied = yaml.safe_load((ROOT / "yaml/52-denied-route.yaml").read_text())
    objects = setup + [denied, post, pre]
    overlay = get("EnterpriseAgentgatewayPolicy", "kernwerk-decision-dlp", optional=True)
    if overlay:
        overlay_source = ROOT.parent / "vision-demo-2026/demo-console/yaml/dlp/08-kernwerk-decision.yaml"
        objects += list(yaml.safe_load_all(overlay_source.read_text()))
    backup = {"context": args.context, "objects": [], "created": []}
    for obj in objects:
        existing = get(obj["kind"], obj["metadata"]["name"], optional=True)
        if existing:
            backup["objects"].append(clean(existing))
        else:
            backup["created"].append({"kind": obj["kind"], "name": obj["metadata"]["name"]})
    # Snapshot first; server validation and every mutation can be rolled back.
    args.backup.write_text(json.dumps(backup, indent=2))
    run("apply", "--dry-run=server", "-f", "-", input=yaml.safe_dump_all(objects))
    run("apply", "-f", "-", input=yaml.safe_dump_all(setup))
    run("rollout", "status", "deploy/routing-policy", "--timeout=180s")
    run("apply", "-f", "-", input=yaml.safe_dump_all(objects[len(setup):]))
    print(f"Applied hybrid routing. Rollback: --context {args.context} --restore {args.backup}")


if __name__ == "__main__":
    main()
