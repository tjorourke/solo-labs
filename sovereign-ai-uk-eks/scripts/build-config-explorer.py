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

# category -> (key, label, items). An item is either (filename, tab) read from yaml/, a
# special ("@eks", tab) for eks/cluster.yaml, or a P(...) placeholder.
GROUPS = [
    ("aws", "AWS (eksctl)", [
        ("@eks", "Cluster, VPC, node groups"),
        P("NLB, security groups", "The public Network Load Balancer is provisioned by the gateway's LoadBalancer Service, and the VPC security groups are managed by EKS. Neither is a standalone file: the NLB shape follows the Gateway (see agentgateway → Gateway), and the security-group posture follows the eksctl cluster definition on the left tab. IMDSv2 with hop-limit 1 is set on the nodes by the model-up step."),
    ]),
    ("agentgateway", "agentgateway", [
        ("30-gateway.yaml",        "Gateway (one door, TLS)"),
        ("31-vllm-backend.yaml",   "Backend → Mistral + route"),
        ("32-jwt-policy.yaml",     "JWT auth"),
        ("34-uk-pii-guard.yaml",   "PII guard"),
        ("35-tracing.yaml",        "OTel tracing"),
        ("60-mcp-tools.yaml",      "MCP tool server"),
        ("61-mcp-authz.yaml",      "Per-tool MCP authz"),
    ]),
    ("mesh", "Istio mesh", [
        P("ztunnel (L4) + access logs", "Solo Enterprise ztunnel runs as a per-node L4 proxy, installed via Helm values in scripts/ambient.sh: profile ambient, LOG_FORMAT json and L7_ENABLED true. The Enterprise build adds structured L4 and L7 HTTP access logs and request metrics on top of upstream ztunnel, so every hop is logged with source and destination SPIFFE identity. These values move into their own tab here once extracted from the script."),
        P("waypoint (L7)", "The L7 waypoint is an enterprise-agentgateway waypoint that carries HTTP-level policy for the mesh: JWT, CEL authorization and per-tool MCP authorization. Applied through the agentgateway install; its config lands here as the layer is finalised."),
        P("istiod values", "istiod runs the ambient profile with its CA delegated to Vault via istio-csr (ENABLE_CA_SERVER off). Installed as Helm values in scripts/istio-csr.sh."),
    ]),
    ("vault", "Vault / CA", [
        P("PKI role + Issuer", "The mesh CA is Vault: a root and intermediate PKI, a signing role keyed for both ECDSA (ztunnel) and RSA (istiod), and a cert-manager Issuer that fronts it. Applied by scripts/vault.sh; the rendered objects land here once extracted."),
        P("KMS auto-unseal", "Vault runs raft-backed and auto-unseals from an AWS KMS key in eu-west-2, reached with an IRSA role, so no unseal key or AWS credential lives in the cluster. Configured in the Vault Helm values in scripts/vault.sh."),
    ]),
    ("kagent", "kagent", [
        P("Agent + Substrate", "kagent config lands here when the runtime is deployed: the Agent and ModelConfig objects, and the Agent Substrate settings that sandbox agents under gVisor on the isolated node group."),
        P("gVisor RuntimeClass", "The RuntimeClass and the tainted sandbox node group that gVisor agents schedule onto. Coming with the kagent layer."),
    ]),
    ("agentregistry", "agentregistry", [
        P("Catalogue + governance", "agentregistry config lands here when it is deployed: the registry install, the catalogue of agents and MCP servers, and the governance policy over what may be registered and deployed."),
    ]),
    ("network", "Network (L4)", [
        ("33-models-networkpolicy.yaml", "Model ingress lock"),
        ("36-egress-lockdown.yaml",      "Egress default-deny"),
        ("70-rogue-agent.yaml",          "Rogue agent + brokered egress"),
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
    ("platform", "Platform (Kubernetes)", [
        ("00-storage.yaml",           "Namespace + weights PVC"),
        ("01-storageclass-gp3.yaml",  "gp3 StorageClass"),
        ("50-pdb.yaml",               "PodDisruptionBudgets"),
    ]),
    ("observability", "Observability", [
        ("80-gateway-monitoring.yaml", "Gateway detector + SOC alert"),
        P("Prometheus + Alertmanager", "kube-prometheus-stack provides Prometheus, Grafana and Alertmanager, installed as Helm values in scripts/observability.sh. Alertmanager routes to an in-cluster inbox, and only alerts marked notify=soc reach the SOC inbox, so a real detection is never buried under stock Kubernetes noise. The concrete detection rule, the gateway PodMonitor and the UnauthorizedModelAccess alert, is the file on the left tab."),
        P("Loki + Grafana + OTel", "Loki for logs, Grafana to view them, and the OpenTelemetry collector the gateway tracing points at. Coming with the observability layer."),
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
        for entry in files:
            if isinstance(entry, dict):          # placeholder
                items.append({"tab": entry["tab"], "placeholder": True, "note": entry["note"]})
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
