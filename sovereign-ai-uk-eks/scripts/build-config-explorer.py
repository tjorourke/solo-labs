#!/usr/bin/env python3
"""Generate the config-explorer data on the Part 1 page from the real yaml/ files.

Config shown on a page must come from its source, never be pasted, or the page drifts
from what is deployed. This reads sovereign-ai-uk-eks/yaml/*, sanitises it (account ids
to a placeholder, any secret-shaped value redacted), groups it by product category, and
writes the JSON into the <script id="cfg-data"> block in index.html. Wired into the
pre-commit hook so it regenerates whenever the yaml changes.

Run: python3 scripts/build-config-explorer.py
"""
import json, re, sys, pathlib

LAB = pathlib.Path(__file__).resolve().parents[1]
YAML = LAB / "yaml"
PAGE = LAB / "index.html"

# category -> label, and the ordered files in it with a human tab name.
GROUPS = [
    ("agentgateway", "agentgateway", [
        ("30-gateway.yaml",        "Gateway (one door, TLS)"),
        ("31-vllm-backend.yaml",   "Backend → Mistral + route"),
        ("32-jwt-policy.yaml",     "JWT auth"),
        ("34-uk-pii-guard.yaml",   "PII guard"),
        ("35-tracing.yaml",        "OTel tracing"),
    ]),
    ("network", "Network (L4)", [
        ("33-models-networkpolicy.yaml", "Model ingress lock"),
        ("36-egress-lockdown.yaml",      "Egress default-deny"),
    ]),
    ("policy", "Kyverno + PSA", [
        ("40-policies.yaml", "Admission policies"),
    ]),
    ("keycloak", "Keycloak (JWT issuer)", [
        ("37-keycloak.yaml",       "Keycloak deploy"),
        ("37-keycloak-realm.json", "Realm + clients"),
    ]),
    ("model", "Model / vLLM", [
        ("20-vllm.yaml",             "vLLM serving Mistral"),
        ("39-model-restore-job.yaml","Weights restore (S3)"),
        ("10-model-sync-job.yaml",   "Weights sync (first pull)"),
    ]),
    ("storage", "Storage", [
        ("00-storage.yaml",           "Namespace + weights PVC"),
        ("01-storageclass-gp3.yaml",  "gp3 StorageClass"),
    ]),
]

# 12-digit AWS account ids -> placeholder (belt and braces; yaml already uses one).
ACCT = re.compile(r"\b\d{12}\b")
# redact secret-shaped values: key: value where key looks sensitive.
SECRET_KEY = re.compile(
    r"(?im)^(\s*[\"']?(?:[a-z0-9_.-]*(?:password|secret|licensekey|license_key|token|apikey|api_key|clientsecret)[a-z0-9_.-]*)[\"']?\s*[:=]\s*)(.+)$"
)

def sanitise(text: str) -> str:
    text = ACCT.sub("<AWS_ACCOUNT_ID>", text)
    def redact(m):
        val = m.group(2).strip()
        # leave obvious non-secrets (booleans, refs, empty, demo 'admin') visible; redact real-looking values
        if val.lower() in ("admin", "true", "false", '""', "''", "root") or val.startswith(("{", "[", "&", "*")):
            return m.group(0)
        return m.group(1) + "<redacted>"
    return SECRET_KEY.sub(redact, text)

def main() -> int:
    data = []
    missing = []
    for cat, label, files in GROUPS:
        items = []
        for fname, tab in files:
            p = YAML / fname
            if not p.exists():
                missing.append(fname); continue
            items.append({"tab": tab, "file": fname, "yaml": sanitise(p.read_text())})
        if items:
            data.append({"cat": cat, "label": label, "items": items})

    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    html = PAGE.read_text()
    new, n = re.subn(
        r'(<script id="cfg-data" type="application/json">).*?(</script>)',
        lambda m: m.group(1) + payload + m.group(2),
        html, count=1, flags=re.S,
    )
    if n != 1:
        print("build-config-explorer: cfg-data script block not found in index.html", file=sys.stderr)
        return 1
    if new != html:
        PAGE.write_text(new)
    files_n = sum(len(g["items"]) for g in data)
    print(f"build-config-explorer: {files_n} config files across {len(data)} categories"
          + (f"; missing {missing}" if missing else ""))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
