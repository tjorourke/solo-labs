#!/usr/bin/env python3
"""Give the demo IdP its group memberships and include groups in Agentdesktop tokens.

The identities are lab fixtures, not gateway configuration. Existing enrolled
devices must sign in again to refresh the IdP claims captured at enrolment.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--realm", default="corp")
    parser.add_argument("--client", default="agentdesktop")
    args = parser.parse_args()
    kube = ["kubectl", "--context", args.context, "-n", "keycloak"]
    pod = subprocess.check_output(kube + ["get", "pods", "-l", "app=keycloak", "-o", "jsonpath={.items[0].metadata.name}"], text=True)

    def admin(*parts):
        return subprocess.check_output(kube + ["exec", pod, "--", "/opt/keycloak/bin/kcadm.sh", *parts], text=True).strip()

    admin("config", "credentials", "--server", "http://localhost:8080", "--realm", "master",
          "--user", "admin", "--password", os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"))
    clients = json.loads(admin("get", "clients", "-r", args.realm, "-q", "clientId=" + args.client))
    if len(clients) != 1:
        raise SystemExit("Expected exactly one Agentdesktop OIDC client")
    client = clients[0]["id"]
    mappers = json.loads(admin("get", f"clients/{client}/protocol-mappers/models", "-r", args.realm))
    mapper = {"name": "routing-groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
              "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                         "access.token.claim": "true", "userinfo.token.claim": "true"}}
    existing = next((m for m in mappers if m["name"] == mapper["name"]), None)
    fields = [item for key, value in mapper.items() for item in ("-s", key + "=" + (json.dumps(value) if isinstance(value, dict) else value))]
    resource = f"clients/{client}/protocol-mappers/models" + ("/" + existing["id"] if existing else "")
    admin("update" if existing else "create", resource, "-r", args.realm, *fields)

    fixture = ROOT / "agentgateway-inference-task-routing-eks/identity/demo-users.json"
    memberships = json.loads(fixture.read_text())
    groups = {g["name"]: g["id"] for g in json.loads(admin("get", "groups", "-r", args.realm))}
    for name in sorted({g for values in memberships.values() for g in values}):
        if name not in groups:
            groups[name] = admin("create", "groups", "-r", args.realm, "-s", "name=" + name, "-i")
    for name, names in memberships.items():
        users = json.loads(admin("get", "users", "-r", args.realm, "-q", "username=" + name, "-q", "exact=true"))
        if not users:
            uid = admin("create", "users", "-r", args.realm, "-i", "-s", "username=" + name,
                        "-s", "enabled=true", "-s", "emailVerified=true", "-s", "email=" + name + "@corp.example",
                        "-s", "firstName=" + name.capitalize(), "-s", "lastName=Corp")
            admin("set-password", "-r", args.realm, "--username", name, "--new-password", "password")
        else:
            uid = users[0]["id"]
        for group in names:
            admin("update", f"users/{uid}/groups/{groups[group]}", "-r", args.realm, "-n")
        print(f"IdP fixture {name}: {', '.join(names)}")
    print("Groups included in ID tokens. Re-enrol existing devices to refresh their stored IdP claims.")


if __name__ == "__main__":
    main()
