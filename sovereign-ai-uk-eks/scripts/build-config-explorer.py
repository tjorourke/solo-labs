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
EKS = LAB / "eks"
PAGE = LAB / "index.html"

# A placeholder tab: config that exists as Helm values in the mirrored scripts, or a layer
# still landing. Shows a note in the pane instead of a file, so the category is present and
# honest rather than missing. (tab-label, note).
def P(label, note):
    return {"placeholder": True, "tab": label, "note": note}

# A shell-heredoc tab: the config is applied by a deploy script through a heredoc (helm
# values, kubectl apply, a Vault policy). Extract that block verbatim so the page shows the
# real thing the cluster runs, not a paraphrase. (script-path, heredoc-marker, tab, nth).
# nth picks which block when a script opens several heredocs with the same marker (e.g.
# ambient.sh opens EOF for istiod, then cni, then ztunnel).
def SH(script, marker, label, nth=1):
    return {"sh": script, "marker": marker, "tab": label, "nth": nth}

def extract_heredoc(text: str, marker: str, nth: int = 1):
    """Return the body between the nth `<<MARKER` opener and its closing `MARKER` line.

    Handles `<<MARKER`, `<<'MARKER'`, `<<"MARKER"` and `<<-MARKER`, and openers that are
    not at end of line (e.g. `... <<'SCRIPT' | kubectl apply -f -`). Returns None if the
    nth block is not found.
    """
    lines = text.split("\n")
    opener = re.compile(r"<<-?\s*(['\"]?)" + re.escape(marker) + r"\1(?![A-Za-z0-9_])")
    found = 0
    i, n = 0, len(lines)
    while i < n:
        if opener.search(lines[i]):
            found += 1
            body, j = [], i + 1
            while j < n and lines[j].strip() != marker:
                body.append(lines[j])
                j += 1
            if found == nth:
                return "\n".join(body)
            i = j + 1
            continue
        i += 1
    return None

# category -> (key, label, items). An item is either (filename, tab) read from yaml/, a
# special ("@eks", tab) for eks/cluster.yaml, an SH(...) heredoc block from a deploy
# script, or a P(...) placeholder.
GROUPS = [
    ("aws", "AWS (eksctl)", [
        ("@eks", "Cluster, VPC, node groups"),
        P("NLB, security groups", "There is no standalone NLB or security-group file. The public Network Load Balancer is provisioned by the gateway's LoadBalancer Service (an L4 passthrough that terminates TLS at the agentgateway pod, not at the NLB, see agentgateway → Gateway), and the VPC, subnets, private-networking node groups and security groups all come from the eksctl cluster definition on the left tab. Control-plane audit and authenticator logs go to CloudWatch (see the cloudWatch block there)."),
    ]),
    ("agentgateway", "agentgateway", [
        ("30-gateway.yaml",        "Gateway (one door, TLS)"),
        ("31-vllm-backend.yaml",   "Backend → Mistral + route"),
        ("32-jwt-policy.yaml",     "JWT auth"),
        ("38-rate-limit.yaml",     "Per-identity rate limit"),
        ("34-uk-pii-guard.yaml",   "PII + injection guard"),
        ("35-tracing.yaml",        "OTel tracing"),
        ("60-mcp-tools.yaml",      "MCP tool server"),
        ("61-mcp-authz.yaml",      "Per-tool MCP authz"),
        ("92-artifactory-egress-gateway.yaml", "Egress broker (GET/HEAD)"),
    ]),
    ("mesh", "Istio mesh", [
        SH("scripts/ambient.sh",   "EOF", "ztunnel (L4) + logs", nth=3),
        SH("scripts/istio-csr.sh", "EOF", "istiod (CA → Vault)", nth=1),
    ]),
    ("vault", "Vault (secrets + CA)", [
        SH("scripts/vault.sh", "POLICY", "Signing policy"),
        SH("scripts/vault.sh", "ISSUER", "cert-manager Issuer"),
        SH("scripts/vault.sh", "EOF",    "KMS auto-unseal"),
        ("45-vault-secrets.yaml", "Secrets via CSI (KV v2)"),
    ]),
    ("kagent", "kagent", [
        SH("scripts/kagent.sh",    "EOF",  "kagent install (OIDC → Keycloak)"),
        SH("scripts/substrate.sh", "YAML", "gVisor RuntimeClass", nth=1),
        SH("scripts/substrate.sh", "YAML", "gVisor installer",    nth=2),
    ]),
    ("agentregistry", "agentregistry", [
        SH("scripts/ar-agent.sh", "AGENT",  "Agent (catalogue entry)"),
        SH("scripts/ar-agent.sh", "DEPLOY", "Runtime + Deployment (kagent)"),
        SH("scripts/ar-agent.sh", "ROGUE",  "The agent admission refuses"),
    ]),
    ("network", "Network (L4)", [
        ("33-models-networkpolicy.yaml", "Model ingress lock"),
        ("36-egress-lockdown.yaml",      "Egress default-deny (apps)"),
        ("70-rogue-agent.yaml",          "Rogue agent + brokered egress"),
        ("90-internal-api.yaml",         "Internal SSRF target"),
        ("91-artifactory-egress.yaml",   "Brokered egress: Artifactory"),
        ("93-registry-readonly.yaml",    "Registry read-only (L7)"),
        ("99-default-deny-egress.yaml",  "Default-deny egress baseline"),
        SH("scripts/dns.sh", "DOMAINS",  "DNS firewall allowlist"),
        SH("scripts/registry-mirror.sh", "DS", "Containerd → in-region ECR mirror"),
    ]),
    ("policy", "Kyverno + PSA", [
        ("40-policies.yaml", "Admission policies"),
        ("41-hardening.yaml", "Restricted-subset + supply chain + RBAC"),
        ("42-agent-admission.yaml", "Agents only from the registry"),
        ("43-serviceaccount-hardening.yaml", "ServiceAccount hardening"),
        ("44-resource-quotas.yaml", "ResourceQuota per namespace"),
        ("82-trivy-cve-gate.yaml", "CVE gate (trivy)"),
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
    ("platform", "Platform (Kubernetes)", [
        ("00-storage.yaml",           "Namespace + weights PVC"),
        ("01-storageclass-gp3.yaml",  "gp3 StorageClass"),
        ("50-pdb.yaml",               "PodDisruptionBudgets"),
    ]),
    ("backups", "Backups (Velero + Vault)", [
        SH("scripts/velero.sh", "YAML", "On-demand backup", 1),
        SH("scripts/velero.sh", "YAML", "Daily schedule", 2),
        SH("scripts/velero.sh", "JSON", "Velero IAM policy"),
    ]),
    ("observability", "Observability", [
        ("80-gateway-monitoring.yaml", "Gateway detector + SOC alert"),
        ("81-mesh-observability.yaml", "Mesh metrics: ztunnel + waypoint"),
        SH("scripts/observability.sh", "VALUES", "Prometheus + Grafana + Alertmanager"),
    ]),
]

# 12-digit AWS account ids -> placeholder (belt and braces; yaml already uses one).
ACCT = re.compile(r"\b\d{12}\b")
# redact secret-shaped values: key: value where key looks sensitive. The whitespace
# classes are horizontal-only ([^\S\n]) on purpose: a plain `\s*` would match the newline
# after a bare mapping key (e.g. `secret:`) and swallow the following line, dropping its
# key. A key and its scalar value live on one line, so keep the match on one line.
SECRET_KEY = re.compile(
    r"(?im)^([^\S\n]*[\"']?(?:[a-z0-9_.-]*(?:password|secret|licensekey|license_key|token|apikey|api_key|clientsecret)[a-z0-9_.-]*)[\"']?[^\S\n]*[:=][^\S\n]*)(.+)$"
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
        for entry in files:
            if isinstance(entry, dict) and entry.get("placeholder"):
                items.append({"tab": entry["tab"], "placeholder": True, "note": entry["note"]})
                continue
            if isinstance(entry, dict) and entry.get("sh"):   # heredoc block from a deploy script
                sp = LAB / entry["sh"]
                shown = f"{entry['sh']} ({entry['marker']})"
                if not sp.exists():
                    missing.append(entry["sh"]); continue
                block = extract_heredoc(sp.read_text(), entry["marker"], entry.get("nth", 1))
                if block is None:
                    missing.append(shown); continue
                items.append({"tab": entry["tab"], "file": shown, "yaml": sanitise(block)})
                continue
            fname, tab = entry
            if fname == "@eks":                  # eks/cluster.yaml lives outside yaml/
                p = EKS / "cluster.yaml"
                shown = "eks/cluster.yaml"
            else:
                p = YAML / fname
                shown = "yaml/" + fname
            if not p.exists():
                missing.append(fname); continue
            items.append({"tab": tab, "file": shown, "yaml": sanitise(p.read_text())})
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
