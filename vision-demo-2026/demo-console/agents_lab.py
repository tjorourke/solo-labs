#!/usr/bin/env python3
"""Code-free agents: catalog, YAML, apply on kind-mesh1."""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

MESH = os.environ.get("MESH_CONTEXT", "kind-mesh1")
NS = "kagent"
ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
CATALOG = json.loads((DATA / "agent-catalog.json").read_text())
STORE = DATA / "my-agents.json"
SKILLS_DIR = DATA / "skills"
RUNTIME_DIR = ROOT / "agent-runtime"
IMAGE = "localhost:5001/my-agents:3"

# Every agent this wizard deploys gets its own identity on the model gateway, so the
# decisions view names the agent rather than whoever's token it borrowed. The JWT is
# signed with the task-routing lab's own key, which the gateway's inline JWKS trusts.
ROUTING_CTX = os.environ.get("ROUTING_CONTEXT") or os.environ.get("MODEL_ROUTING_CONTEXT") or next(
    (n for n in subprocess.run(["kubectl", "config", "get-contexts", "-o", "name"],
                               text=True, capture_output=True).stdout.split()
     if n.endswith("cluster/model-routing") or n == "model-routing"), "")
ROUTING_NS = "agentgateway-system"
GATEWAY_URL = os.environ.get("MODEL_GATEWAY_URL", f"https://{os.environ.get('AGW_HOST', 'agw.example.com')}/v1")
SIGNING_KEY = Path(os.environ.get("MODEL_GATEWAY_SIGNING_KEY", ROOT.parents[1] / "agentgateway-inference-task-routing-eks" / "identity" / "signing-key.pem"))
# Private only. A new agent is not entitled to a frontier model because someone typed a
# name into a wizard; widening that is a platform decision, made on /approvals.
AGENT_POOLS = ["private"]
TOKEN_DAYS = 30
AR_RUNTIME = "kind-kagent"
GITHUB_WAYPOINT = ROOT / "yaml" / "github-waypoint.yaml"
GITHUB_POLICY = "github-per-agent"
DAYLIGHT_YAML = ROOT / "yaml" / "daylight-mcp.yaml"
DAYLIGHT_REGISTRY = ROOT / "yaml" / "daylight-mcp-registry.yaml"
# The approval decision lives on the AgentRegistry MCPServer. No label, or any value but
# "true", means a platform admin approves. "true" means My agents writes the grant itself.
AUTO_APPROVE_LABEL = "mcp.governance/auto-approve"
# MCP servers that sit behind agentgateway with a default-deny policy per server. The
# others are reached direct, so for them approval is recorded here but not enforced.
GATEWAY_MCP = {
    "github": {"backend": "github-mcp", "policy": GITHUB_POLICY},
    "daylight": {"backend": "daylight-mcp", "policy": "daylight-per-agent"},
    "quiz": {"backend": "quiz-mcp", "policy": "quiz-per-agent"},
    "excuses": {"backend": "excuses-mcp", "policy": "excuses-per-agent"},
}
# Every MCP route behind the gateway demands a token from this key, and only the agents a
# server is granted to get past the route. The key is made per install and never committed;
# the public half is inlined into the route policies.
MCP_KEY = DATA / "mcp-signing-key.pem"
MCP_ISSUER = "https://my-agents.lab"
MCP_AUDIENCE = "mcp-gateway"
MCP_TOKEN_HEADER = {"name": "Authorization", "value": "Bearer ${MCP_TOKEN}"}
FUN_YAML = ROOT / "yaml" / "fun-mcp.yaml"
FUN_REGISTRY = ROOT / "yaml" / "fun-mcp-registry.yaml"
# Servers the platform publishes from a manifest, with their labels: the cluster side,
# and the AgentRegistry record that carries the approval label.
MANAGED_MCP = {
    "daylight": (DAYLIGHT_YAML, DAYLIGHT_REGISTRY),
    "quiz": (FUN_YAML, FUN_REGISTRY),
    "excuses": (FUN_YAML, FUN_REGISTRY),
}
GITHUB_MCP_URL = "http://github-mcp.kagent.svc.cluster.local/"
SKILL_PACKAGES = ROOT.parents[0] / "demo-scripts" / "agentregistry" / "skill"
SKILL_GIT = "https://github.com/tjorourke/solo-labs.git"
# Where a skill package sits inside the mirror. AgentRegistry has no inline body for a
# Skill: spec.source.repository is the only content channel and the controller pins a
# commit, so an authored skill has to reach git before the registry can resolve it.
SKILL_SUBFOLDER = "vision-demo-2026/demo-scripts/agentregistry/skill"
# Prompts are flat files, not packages: a Prompt carries its content inline, so there is
# nothing for the registry to clone and nothing to pin.
PROMPT_PACKAGES = ROOT.parents[0] / "demo-scripts" / "agentregistry" / "prompt"
REPO = ROOT.parents[1]


def kc(*args, check=True):
    return subprocess.run(
        ["kubectl", "--context", MESH, *args],
        check=check, text=True, capture_output=True,
    )


def ystr(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s[:48] or "agent"


def load_store():
    if STORE.is_file():
        return json.loads(STORE.read_text())
    return {"agents": []}


def save_store(store):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(store, indent=2) + "\n")


def tool_ids(server):
    out = []
    for t in server.get("tools") or []:
        out.append(t["id"] if isinstance(t, dict) else t)
    return out


def catalog():
    ensure_skills()
    ensure_mcps()
    local = {s["id"]: s for s in CATALOG["skills"]}
    skills = _skills_from_registry()
    seen = {s["id"] for s in skills}
    for s in CATALOG["skills"]:
        if s["id"] in seen:
            continue
        body = (SKILLS_DIR / f"{s['id']}.md").read_text() if (SKILLS_DIR / f"{s['id']}.md").is_file() else ""
        skills.append({**s, "body": body, "ready": False})
    for s in skills:
        loc = local.get(s["id"])
        if loc:
            s["domain"] = s.get("domain") or loc.get("domain") or ""
            if not s.get("title"):
                s["title"] = loc["title"]
            if not s.get("description"):
                s["description"] = loc["description"]
    skills.sort(key=lambda s: (0 if s["id"] == "github-briefing" else 1, s.get("title") or s["id"]))
    return {"skills": skills, "mcp": mcp_catalog(), "platform": platform(),
            "autoApproveLabel": AUTO_APPROVE_LABEL}


def _skill_ready(row: dict) -> bool:
    for c in (row.get("status") or {}).get("conditions") or []:
        if c.get("type") == "Ready":
            return c.get("status") == "True"
    return False


def _skills_from_registry() -> list:
    _arctl_login()
    listed = _arctl("get", "skills", "-o", "json", timeout=20)
    if listed.returncode != 0 or not listed.stdout.strip():
        return []
    try:
        rows = json.loads(listed.stdout)
    except json.JSONDecodeError:
        return []
    if isinstance(rows, dict):
        rows = rows.get("items") or [rows]
    out = []
    for row in rows or []:
        meta = row.get("metadata") or {}
        spec = row.get("spec") or {}
        name = meta.get("name") or ""
        if not name:
            continue
        body = ""
        pack = SKILL_PACKAGES / name / "SKILL.md"
        local = SKILLS_DIR / f"{name}.md"
        if pack.is_file():
            body = pack.read_text()
        elif local.is_file():
            body = local.read_text()
        out.append({
            "id": name,
            "title": spec.get("title") or name,
            "description": spec.get("description") or "",
            "domain": "",
            "body": body,
            "ready": _skill_ready(row),
        })
    return out


def ensure_prompts():
    """Publish the packaged prompts, so the wizard's pull list is not empty on a fresh
    registry. Without these the only Prompts in AgentRegistry are the ones this wizard
    wrote for agents it deployed, which is nothing to start from."""
    if not PROMPT_PACKAGES.is_dir():
        return
    ok, _ = _arctl_login()
    if not ok:
        return
    for path in sorted(PROMPT_PACKAGES.glob("*.yaml")):
        _arctl("apply", "-f", str(path), timeout=30)


def registry_prompts() -> list:
    """Prompts in AgentRegistry, body included. Used to fill the wizard's prompt box.

    Prompt is the one kind that carries its content inline, so the whole body comes back
    with the list and there is nothing further to fetch. Every agent this wizard deploys
    also writes a <name>-prompt, so those are marked and sorted last rather than hidden:
    pulling an existing agent's prompt as a starting point is the useful case.
    """
    ensure_prompts()
    listed = _arctl("get", "prompts", "-o", "json", timeout=20)
    if listed.returncode != 0 or not listed.stdout.strip():
        return []
    try:
        rows = json.loads(listed.stdout)
    except json.JSONDecodeError:
        return []
    if isinstance(rows, dict):
        rows = rows.get("items") or [rows]
    mine = {a["name"] for a in load_store()["agents"]}
    out = []
    for row in rows or []:
        meta = row.get("metadata") or {}
        spec = row.get("spec") or {}
        name = meta.get("name") or ""
        if not name:
            continue
        # Match the stem against the store, not the suffix alone, so a hand-written
        # prompt that happens to end in -prompt is not filed under someone's agent.
        stem = name[: -len("-prompt")] if name.endswith("-prompt") else ""
        out.append({
            "id": name,
            "tag": meta.get("tag") or "latest",
            "description": spec.get("description") or "",
            "content": spec.get("content") or "",
            "generated": bool(stem) and stem in mine,
            "updated": meta.get("updatedAt") or meta.get("createdAt") or "",
        })
    return sort_prompts(out)


def sort_prompts(rows: list) -> list:
    """Standalone prompts first, the wizard's own last, newest first inside each group."""
    newest = sorted(rows, key=lambda p: p.get("updated") or "", reverse=True)
    return sorted(newest, key=lambda p: 1 if p.get("generated") else 0)


def ensure_skills():
    """Publish every packaged skill to AgentRegistry from git, not inline."""
    if not SKILL_PACKAGES.is_dir():
        return
    ok, _ = _arctl_login()
    if not ok:
        return
    for path in sorted(SKILL_PACKAGES.glob("*/skill.yaml")):
        _arctl("apply", "-f", str(path), timeout=30)


def write_skill_package(sid: str, title: str, description: str, body: str) -> Path:
    """Write SKILL.md and skill.yaml for a new skill, in the shape the others use."""
    d = SKILL_PACKAGES / sid
    d.mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(body.rstrip() + "\n")
    (d / "skill.yaml").write_text(
        "apiVersion: ar.dev/v1alpha1\n"
        "kind: Skill\n"
        "metadata:\n"
        f"  name: {sid}\n"
        "spec:\n"
        f"  title: {ystr(title)}\n"
        f"  description: {ystr(description)}\n"
        "  source:\n"
        "    repository:\n"
        f"      url: {SKILL_GIT}\n"
        "      branch: main\n"
        f"      subfolder: {SKILL_SUBFOLDER}/{sid}\n"
    )
    return d


def _git(*args, timeout=60, env=None):
    return subprocess.run(
        ["git", "-C", str(REPO), *args], capture_output=True, text=True, timeout=timeout,
        env={**os.environ, **env} if env else None,
    )


def push_package(d: Path, rel: str, message: str) -> dict:
    """Commit the package on top of origin/main and push it, without touching the checkout.

    The repository this console runs from is usually dirty and often a few commits behind,
    because it is where the labs are written. Committing in place would either sweep up
    another session's half-finished work or fail the push as a non-fast-forward, mid-demo.
    So the blobs go straight into the object store and the commit is built against
    origin/main in a scratch index. Nothing in the working tree moves, no branch is
    checked out, and the files are already on disk for the wizard to use.
    """
    out = {"commit": "", "pushed": False, "detail": ""}
    fetched = _git("fetch", "origin", "main", timeout=120)
    if fetched.returncode != 0:
        out["detail"] = (fetched.stderr or "git fetch failed").strip()[:300]
        return out
    tmp = tempfile.mkdtemp(prefix="skill-index-")
    env = {"GIT_INDEX_FILE": str(Path(tmp) / "index")}
    try:
        read = _git("read-tree", "origin/main", env=env)
        if read.returncode != 0:
            out["detail"] = (read.stderr or "git read-tree failed").strip()[:300]
            return out
        for f in sorted(p for p in d.iterdir() if p.is_file()):
            blob = _git("hash-object", "-w", "--", str(f))
            if blob.returncode != 0:
                out["detail"] = (blob.stderr or "git hash-object failed").strip()[:300]
                return out
            staged = _git("update-index", "--add", "--cacheinfo",
                          f"100644,{blob.stdout.strip()},{rel}/{f.name}", env=env)
            if staged.returncode != 0:
                out["detail"] = (staged.stderr or "git update-index failed").strip()[:300]
                return out
        tree = _git("write-tree", env=env)
        if tree.returncode != 0:
            out["detail"] = (tree.stderr or "git write-tree failed").strip()[:300]
            return out
        commit = _git("commit-tree", tree.stdout.strip(), "-p", "origin/main", "-m", message)
        if commit.returncode != 0:
            out["detail"] = (commit.stderr or "git commit-tree failed").strip()[:300]
            return out
        sha = commit.stdout.strip()
        out["commit"] = sha[:7]
        pushed = _git("push", "origin", f"{sha}:main", timeout=120)
        out["pushed"] = pushed.returncode == 0
        if not out["pushed"]:
            # Someone pushed to main between the fetch and here. Leave it: the package is
            # on disk and registered, and resolving a moving branch with an audience
            # watching is not something to do automatically.
            out["detail"] = (pushed.stderr or "git push failed").strip()[:300]
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def create_skill(spec: dict) -> dict:
    """Author a skill, push it to git, then register it.

    The push is not ceremony. A Skill's body lives in the repository the registry clones,
    so anything reading the skill from AgentRegistry sees nothing until the subfolder is on
    the mirror. The wizard can use it straight away regardless, because render_yaml inlines
    the body from disk.
    """
    title = (spec.get("title") or "").strip()
    description = (spec.get("description") or "").strip()
    body = (spec.get("body") or "").strip()
    if not title:
        return {"ok": False, "error": "Give the skill a title."}
    if not body:
        return {"ok": False, "error": "Write the skill body. That is the skill."}
    sid = slug(title)
    if (SKILL_PACKAGES / sid).exists():
        return {"ok": False, "error": f"A skill package called {sid} is already there."}
    if any(s["id"] == sid for s in _skills_from_registry()):
        return {"ok": False, "error": f"{sid} is already in the registry."}

    d = write_skill_package(sid, title, description, body)
    rel = f"{SKILL_SUBFOLDER}/{sid}"

    out = {"ok": True, "id": sid, "title": title, "commit": "", "pushed": False,
           "registered": False, "detail": ""}
    out.update(push_package(d, rel, f"vision-demo console: add the {title} skill"))

    _arctl_login()
    applied = _arctl("apply", "-f", str(d / "skill.yaml"), timeout=30)
    out["registered"] = applied.returncode == 0
    if not out["registered"]:
        out["detail"] = ((applied.stderr or applied.stdout) or "arctl apply failed").strip()[:300]
    return out


def ensure_mcps():
    """Keep the Telco inventory and Site daylight MCPs running. Kubernetes SRE is kagent-tools."""
    paths = [ROOT / "yaml" / "telco-inventory.yaml"]
    paths += list(dict.fromkeys(cluster for cluster, _ in MANAGED_MCP.values()))
    for yaml_path in paths:
        if yaml_path.is_file():
            kc("apply", "-f", str(yaml_path), check=False)
    # Default deny from the first moment: a managed server with no policy would be open.
    for sid in MANAGED_MCP:
        got = kc("-n", NS, "get", "enterpriseagentgatewaypolicy", GATEWAY_MCP[sid]["policy"], check=False)
        if got.returncode != 0:
            _apply_policy(sid)


_MCP_LABELS = {"at": 0.0, "labels": {}}
# Registry names whose record sends the agent's MCP token. Filled by _registry_mcp_rows.
_MCP_HAS_TOKEN = set()


def ensure_registry_mcps(existing: dict | None = None):
    """The platform owns MCPServer records; agents only reference them.

    Re-applying an MCPServer without its labels wipes them, so an agent's stack must not
    publish one. This creates any catalogue server the registry lacks, and publishes Site
    daylight from its manifest when the record or its label is missing.
    """
    if existing is None:
        existing = _registry_mcp_rows()
    published = set()
    for server in CATALOG["mcp"]:
        rname = registry_mcp_name(server["id"])
        managed = MANAGED_MCP.get(server["id"])
        gated = server["id"] in GATEWAY_MCP
        if managed:
            stale = (existing.get(rname, {}).get(AUTO_APPROVE_LABEL) != "true"
                     or rname not in _MCP_HAS_TOKEN)
            if stale and managed[1] not in published:
                _arctl("apply", "-f", str(managed[1]), timeout=30)
                published.add(managed[1])
            continue
        # A gateway route demands the agent's MCP token, so its record must send one.
        if rname in existing and (not gated or rname in _MCP_HAS_TOKEN):
            continue
        if not server.get("url"):
            continue
        doc = (
            "apiVersion: ar.dev/v1alpha1\n"
            "kind: MCPServer\n"
            "metadata:\n"
            f"  name: {rname}\n"
            "spec:\n"
            f"  title: {ystr(server['name'])}\n"
            f"  description: {ystr(server['description'])}\n"
            "  remote:\n"
            "    type: streamable-http\n"
            f"    url: {server['url']}\n"
        )
        if gated:
            doc += ("    headers:\n"
                    f"    - name: {MCP_TOKEN_HEADER['name']}\n"
                    f"      value: {json.dumps(MCP_TOKEN_HEADER['value'])}\n")
        tmp = DATA / f"tmp-mcp-{rname}.yaml"
        tmp.write_text(doc)
        _arctl("apply", "-f", str(tmp), timeout=30)
        tmp.unlink(missing_ok=True)


def setup_platform() -> list:
    """Everything My agents needs on mesh1, from git: MCP servers, gateway backends,
    default-deny policies and the AgentRegistry records with their approval labels.
    Idempotent. Images are built by demo-scripts/my-agents-setup.sh before this runs."""
    out = []
    ensure_mcps()
    out.append("MCP servers and gateway backends applied: telco, Site daylight, IT pub quiz, Excuse generator")
    if _copy_github_pat():
        ensure_github_waypoint()
        out.append("GitHub MCP waypoint applied, PAT copied into kagent")
    else:
        out.append("GitHub MCP skipped: no github-mcp-pat secret in agentgateway-system (run llm-gateway.sh)")
    for sid in GATEWAY_MCP:
        if sid == "github" and kc("-n", NS, "get", "enterpriseagentgatewaybackend", "github-mcp", check=False).returncode != 0:
            continue
        _apply_policy(sid)
    out.append("Gateway policies rebuilt from the agent store (default deny where nobody is granted)")
    ok, detail = _arctl_login()
    if not ok:
        out.append(f"AgentRegistry records skipped: {detail}")
        return out
    ensure_registry_mcps()
    out.append("AgentRegistry MCPServer records published")
    return out


def platform_rows() -> list:
    """One row per catalogue server: registry record, approval tier, gateway policy."""
    labels = registry_mcp_labels(force=True)
    rows = []
    for m in CATALOG["mcp"]:
        rname = registry_mcp_name(m["id"])
        policy = "not behind the gateway"
        if m["id"] in GATEWAY_MCP:
            got = kc("-n", NS, "get", "enterpriseagentgatewaypolicy", GATEWAY_MCP[m["id"]]["policy"],
                     "-o", "jsonpath={.spec.backend.mcp.authorization.policy.matchExpressions[0]}", check=False)
            if got.returncode != 0:
                policy = "MISSING"
            else:
                sas = re.findall(r'serviceAccount == "([^"]+)"', got.stdout or "")
                policy = ("allows " + ", ".join(sas)) if sas else "deny all"
        rows.append({
            "server": m["name"], "registry": rname if rname in labels else "MISSING",
            "tier": "auto-approve" if mcp_auto_approve(m["id"], labels) else "admin approves",
            "policy": policy,
        })
    return rows


def teardown_platform(force: bool = False) -> list:
    """Remove what setup_platform added for the managed servers.

    Refuses while an agent still uses one: its AgentRegistry Deployment references the
    MCPServer record, and deleting the record under it breaks that agent."""
    users = sorted({a["name"] for a in load_store()["agents"]
                    for m in a.get("mcp") or [] if m.get("id") in MANAGED_MCP and m.get("tools")})
    if users and not force:
        return [f"Not removed: {', '.join(users)} still use these servers. "
                "Delete those agents on My agents first, or run with --force."]
    out = []
    for sid in MANAGED_MCP:
        kc("-n", NS, "delete", "enterpriseagentgatewaypolicy", GATEWAY_MCP[sid]["policy"], "--ignore-not-found", check=False)
    for cluster in dict.fromkeys(c for c, _ in MANAGED_MCP.values()):
        kc("delete", "-f", str(cluster), "--ignore-not-found", check=False)
    out.append("Managed MCP servers, backends and their policies deleted")
    if _arctl_login()[0]:
        for sid in MANAGED_MCP:
            _arctl("delete", "mcp", registry_mcp_name(sid), timeout=30)
        out.append("Their AgentRegistry records deleted")
    _MCP_LABELS["at"] = 0.0
    return out


def _registry_mcp_rows() -> dict:
    p = _arctl("get", "mcps", "-o", "json", timeout=20)
    if p.returncode != 0:
        ok, _ = _arctl_login()
        if not ok:
            return {}
        p = _arctl("get", "mcps", "-o", "json", timeout=20)
    try:
        rows = json.loads(p.stdout or "[]")
    except json.JSONDecodeError:
        return {}
    if isinstance(rows, dict):
        rows = rows.get("items") or [rows]
    out = {}
    _MCP_HAS_TOKEN.clear()
    for r in rows or []:
        meta = r.get("metadata") or {}
        if meta.get("name"):
            out[meta["name"]] = meta.get("labels") or {}
            headers = ((r.get("spec") or {}).get("remote") or {}).get("headers") or []
            if any(h.get("name") == "Authorization" and "${MCP_TOKEN}" in str(h.get("value")) for h in headers):
                _MCP_HAS_TOKEN.add(meta["name"])
    return out


def registry_mcp_labels(force: bool = False) -> dict:
    """Labels on every AgentRegistry MCPServer, by registry name. Cached for 20 seconds."""
    if not force and time.time() - _MCP_LABELS["at"] < 20:
        return _MCP_LABELS["labels"]
    rows = _registry_mcp_rows()
    missing = [m for m in CATALOG["mcp"] if registry_mcp_name(m["id"]) not in rows]
    unlabelled = [sid for sid in MANAGED_MCP
                  if rows.get(registry_mcp_name(sid), {}).get(AUTO_APPROVE_LABEL) != "true"]
    tokenless = [sid for sid in GATEWAY_MCP if registry_mcp_name(sid) not in _MCP_HAS_TOKEN]
    if missing or unlabelled or tokenless:
        ensure_registry_mcps(rows)
        rows = _registry_mcp_rows() or rows
    _MCP_LABELS.update(at=time.time(), labels=rows)
    return rows


def mcp_auto_approve(catalog_id: str, labels: dict | None = None) -> bool:
    labels = registry_mcp_labels() if labels is None else labels
    return (labels.get(registry_mcp_name(catalog_id)) or {}).get(AUTO_APPROVE_LABEL) == "true"


def mcp_catalog() -> list:
    labels = registry_mcp_labels()
    out = []
    for m in CATALOG["mcp"]:
        out.append({
            **m,
            "registryName": registry_mcp_name(m["id"]),
            "autoApprove": mcp_auto_approve(m["id"], labels),
            "enforced": m["id"] in GATEWAY_MCP,
        })
    return out


def platform():
    crds = kc("get", "crd", "agents.kagent.dev", "agents.ar.dev", check=False)
    out = crds.stdout + crds.stderr
    kagent = "agents.kagent.dev" in out and crds.returncode == 0
    # get crd with two names fails if either missing
    kagent = kc("get", "crd", "agents.kagent.dev", check=False).returncode == 0
    registry = kc("get", "crd", "agents.ar.dev", check=False).returncode == 0
    ui = ""
    registry_ui = ""
    envf = ROOT.parents[0] / "demo-scripts" / "agentregistry" / ".env.mesh1"
    if envf.is_file():
        for line in envf.read_text().splitlines():
            if line.startswith("export KAGENT_UI_HOST="):
                ui = "http://" + line.split("=", 1)[1].strip()
            if line.startswith("export ARCTL_API_BASE_URL="):
                registry_ui = line.split("=", 1)[1].strip()
        if registry_ui:
            registry = True
    if not ui:
        try:
            ip = kc("-n", "solo-cost", "get", "svc", "solo-enterprise-ui",
                    "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}", check=False).stdout.strip()
            if ip:
                ui = f"http://{ip}:8080"
        except Exception:
            pass
    return {
        "kagent": kagent,
        "registry": registry,
        "ui": ui,
        "registry_ui": locals().get("registry_ui") or "",
        "mesh": MESH,
        "note": None if kagent else (
            "kagent is not installed on mesh1 yet. YAML is still generated. "
            "Stand it up with demo-scripts/agentregistry/setup-mesh1.sh, then deploy again."
        ),
    }


def skill_text(ids, by_id=None):
    parts = []
    if by_id is None:
        by_id = {s["id"]: s for s in catalog()["skills"]}
    for i in ids:
        s = by_id.get(i)
        if not s:
            continue
        parts.append((s.get("body") or "").strip())
    return "\n\n".join(p for p in parts if p)


def registry_mcp_name(catalog_id: str) -> str:
    if catalog_id == "everything":
        return "everything-server"
    if catalog_id == "k8s":
        return "k8s-sre"
    if catalog_id == "telco":
        return "telco-inventory"
    if catalog_id == "daylight":
        return "site-daylight"
    if catalog_id == "quiz":
        return "it-pub-quiz"
    if catalog_id == "excuses":
        return "excuse-generator"
    return catalog_id


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _sign_jwt(key: Path, kid: str, claims: dict) -> str:
    def seg(obj):
        return _b64url(json.dumps(obj, separators=(",", ":")).encode())

    signing_input = (seg({"alg": "RS256", "typ": "JWT", "kid": kid}) + "." + seg(claims)).encode()
    sig = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key)],
        input=signing_input, capture_output=True,
    )
    if sig.returncode != 0:
        return ""
    return signing_input.decode() + "." + _b64url(sig.stdout)


def mint_agent_token(name: str) -> str:
    """A JWT whose subject is the agent's own name, signed with the lab key."""
    if not SIGNING_KEY.is_file():
        return ""
    now = int(time.time())
    return _sign_jwt(SIGNING_KEY, "lab-key", {
        "iss": "https://identity.lab",
        "aud": "model-gateway",
        "sub": name,
        "groups": ["model-private"],
        "iat": now,
        "exp": now + TOKEN_DAYS * 86400,
    })


def ensure_mcp_key() -> bool:
    if MCP_KEY.is_file():
        return True
    MCP_KEY.parent.mkdir(parents=True, exist_ok=True)
    made = subprocess.run(["openssl", "genrsa", "-out", str(MCP_KEY), "2048"], capture_output=True)
    if made.returncode != 0:
        return False
    MCP_KEY.chmod(0o600)
    return True


def mcp_jwks() -> str:
    """The public half of the MCP key as the inline JWKS the route policies trust."""
    if not ensure_mcp_key():
        return ""
    mod = subprocess.run(["openssl", "rsa", "-in", str(MCP_KEY), "-noout", "-modulus"],
                         capture_output=True, text=True)
    hexn = (mod.stdout or "").strip().split("=", 1)[-1]
    if mod.returncode != 0 or not hexn:
        return ""
    return json.dumps({"keys": [{"kty": "RSA", "kid": "mcp-key", "use": "sig", "alg": "RS256",
                                 "n": _b64url(bytes.fromhex(hexn)), "e": "AQAB"}]})


def mint_mcp_token(name: str) -> str:
    """The agent's credential for MCP routes: subject is its ServiceAccount name."""
    if not ensure_mcp_key():
        return ""
    now = int(time.time())
    return _sign_jwt(MCP_KEY, "mcp-key", {
        "iss": MCP_ISSUER, "aud": MCP_AUDIENCE, "sub": name,
        "iat": now, "exp": now + TOKEN_DAYS * 86400,
    })


def register_agent_identity(name: str, pools: list | None = None) -> dict:
    """Check that the signed agent group is recognised, without registering a user.

    The builder gets the platform's private-only role. Adding an agent never rewrites
    an AGW policy or a Rego user directory; the role travels in its signed token.
    """
    want = list(pools or AGENT_POOLS)
    if set(want) != set(AGENT_POOLS):
        return {"ok": False, "detail": "This wizard issues private-only identities; wider access requires a platform role."}
    rk = ["kubectl", "--context", ROUTING_CTX, "-n", ROUTING_NS]
    got = subprocess.run(
        rk + ["get", "cm", "routing-policy-data", "-o", "jsonpath={.data.routing-data\\.json}"],
        capture_output=True, text=True,
    )
    if got.returncode != 0:
        return {"ok": False, "detail": (got.stderr or "cannot reach the routing cluster").strip()[:160]}
    try:
        data = json.loads(got.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "detail": "routing roles are not readable JSON"}
    if data.get("roles", {}).get("model-private", {}).get("allowed_model_pools") != AGENT_POOLS:
        return {"ok": False, "detail": "The platform's model-private role is missing or has changed."}
    return {"ok": True, "detail": f"{name} carries the signed model-private group; no gateway change", "restarted": False}


def render_yaml(spec: dict) -> str:
    """AgentRegistry stack. kagent only sees this agent after a Deployment."""
    name = slug(spec["name"])
    version = spec.get("version") or "v1"
    desc = spec.get("description") or spec["name"]
    prompt = (spec.get("prompt") or "").rstrip()
    skill_ids = spec.get("skills") or []
    mcp_sel = spec.get("mcp") or []
    # The merged catalogue, not the static JSON: a skill authored in the UI exists in the
    # registry and on disk but was never in data/agent-catalog.json.
    known_skills = {s["id"]: s for s in catalog()["skills"]}
    skills_md = skill_text(skill_ids, known_skills)
    system = prompt
    if skills_md:
        system += "\n\n" + skills_md

    allowed = []
    mcp_docs = []
    mcp_refs = []
    for sel in mcp_sel:
        server = next((m for m in CATALOG["mcp"] if m["id"] == sel.get("id")), None)
        if not server:
            continue
        tools = [t for t in (sel.get("tools") or []) if t in tool_ids(server)]
        if not tools:
            continue
        allowed.extend(tools)
        # A reference only. The platform publishes the MCPServer (ensure_registry_mcps);
        # re-publishing it here would wipe its labels, and with them its approval tier.
        rname = registry_mcp_name(server["id"])
        if rname not in mcp_refs:
            mcp_refs.append(rname)

    skill_docs = []
    for sid in skill_ids:
        s = known_skills.get(sid)
        if not s:
            continue
        skill_docs.append(
            "---\n"
            "apiVersion: ar.dev/v1alpha1\n"
            "kind: Skill\n"
            "metadata:\n"
            f"  name: {sid}\n"
            "spec:\n"
            f"  title: {ystr(s.get('title') or sid)}\n"
            f"  description: {ystr(s.get('description') or '')}\n"
            "  source:\n"
            "    repository:\n"
            f"      url: {SKILL_GIT}\n"
            "      branch: main\n"
            f"      subfolder: {SKILL_SUBFOLDER}/{sid}\n"
        )

    prompt_doc = (
        "# Generated by My agents. Applied with arctl, never kubectl.\n"
        "apiVersion: ar.dev/v1alpha1\n"
        "kind: Prompt\n"
        "metadata:\n"
        f"  name: {name}-prompt\n"
        f"  tag: {version}\n"
        "spec:\n"
        f"  description: {ystr(desc)}\n"
        "  content: |\n"
        f"{indent(system, 4)}\n"
    )
    mcp_ref_yaml = ""
    if mcp_refs:
        mcp_ref_yaml = "  mcpServers:\n" + "".join(
            f"  - kind: MCPServer\n    name: {n}\n    tag: latest\n" for n in mcp_refs
        )
    agent_doc = (
        "---\n"
        "apiVersion: ar.dev/v1alpha1\n"
        "kind: Agent\n"
        "metadata:\n"
        f"  name: {name}\n"
        f"  tag: {version}\n"
        "spec:\n"
        f"  title: {ystr(name)}\n"
        f"  description: {ystr(desc)}\n"
        "  modelProvider: anthropic\n"
        "  modelName: claude-haiku-4-5\n"
        "  source:\n"
        f"    image: {IMAGE}\n"
        f"{mcp_ref_yaml}"
    )
    deploy_doc = (
        "---\n"
        "apiVersion: ar.dev/v1alpha1\n"
        "kind: Deployment\n"
        "metadata:\n"
        f"  name: {name}\n"
        "spec:\n"
        "  targetRef:\n"
        "    kind: Agent\n"
        f"    name: {name}\n"
        f"    tag: {version}\n"
        "  runtimeRef:\n"
        "    kind: Runtime\n"
        f"    name: {AR_RUNTIME}\n"
        "  env:\n"
        "    SYSTEM_MESSAGE: |\n"
        f"{indent(system, 6)}\n"
        f"    AGENT_DESCRIPTION: {ystr(desc)}\n"
    )
    if allowed:
        deploy_doc += f"    ALLOWED_TOOLS: {ystr(json.dumps(allowed))}\n"
        # The MCPServer records send "Authorization: Bearer ${MCP_TOKEN}"; this fills it.
        deploy_doc += f"    MCP_TOKEN: {ystr(spec.get('mcp_token') or '<minted at deploy>')}\n"
    # AgentRegistry Deployment env is literal strings only, with no secretRef, so the
    # agent's token sits in the registry record and the pod env. It is a lab identity,
    # private-pool only and expiring, which is proportionate for that.
    token = spec.get("token") or ""
    if token:
        deploy_doc += f"    MODEL_BASE_URL: {ystr(GATEWAY_URL)}\n"
        deploy_doc += f"    MODEL_API_KEY: {ystr(token)}\n"

    docs = [prompt_doc] + skill_docs + mcp_docs + [agent_doc, deploy_doc]
    return "\n".join(d.strip("\n") for d in docs).rstrip() + "\n"


def indent(text: str, n: int) -> str:
    pad = " " * n
    return "\n".join(pad + line if line.strip() else "" for line in text.splitlines())


def _with_policy(rec: dict) -> dict:
    out = dict(rec)
    out["policy_yaml"] = approved_policy_yaml(out["name"])
    out["policy_preview"] = pending_policy_yaml(out["name"])
    out["auto_policy_yaml"] = auto_policy_yaml(out["name"])
    tiers = mcp_tiers(out)
    out["mcp_auto"] = tiers["auto"]
    out["mcp_restricted"] = tiers["restricted"]
    out["needs_approval"] = bool(tiers["restricted"])
    out["admin_approved"] = bool(out.get("mcp_approved") or out.get("github_approved"))
    return out


def list_agents():
    return [_with_policy(a) for a in load_store()["agents"]]


def get_agent(name: str):
    name = slug(name)
    for a in load_store()["agents"]:
        if a["name"] == name:
            return a
    return None


def next_version(name: str) -> str:
    n = 0
    rec = get_agent(name)
    if rec:
        m = re.match(r"v(\d+)$", str(rec.get("version") or ""))
        if m:
            n = max(n, int(m.group(1)))
    listed = _arctl("get", "agent", name, "--all-tags", "-o", "json", timeout=15)
    if listed.returncode == 0 and listed.stdout.strip():
        try:
            rows = json.loads(listed.stdout)
            if isinstance(rows, dict):
                rows = [rows]
            for row in rows or []:
                tag = str((row.get("metadata") or {}).get("tag") or "")
                m = re.match(r"v(\d+)$", tag)
                if m:
                    n = max(n, int(m.group(1)))
        except json.JSONDecodeError:
            pass
    return f"v{n + 1}"


def create_agent(spec: dict):
    name = slug(spec.get("name") or "")
    if not name:
        return {"ok": False, "error": "Give the agent a name."}
    prompt = (spec.get("prompt") or "").strip()
    if not prompt:
        return {"ok": False, "error": "Write the prompt. That is the agent."}
    # One skill, not a pile. The picker is single-select; this is the server saying so too,
    # for an older client or a hand-rolled POST.
    skills = (spec.get("skills") or [])[:1]
    if skills:
        known = {s["id"] for s in catalog()["skills"]}
        if skills[0] not in known:
            return {"ok": False, "error": f"Unknown skill {skills[0]}."}
    mcp_sel = spec.get("mcp") or []
    for sel in mcp_sel:
        server = next((m for m in CATALOG["mcp"] if m["id"] == sel.get("id")), None)
        if not server:
            return {"ok": False, "error": f"Unknown MCP server {sel.get('id')}."}
        tools = sel.get("tools") or []
        unknown = [t for t in tools if t not in tool_ids(server)]
        if unknown:
            return {"ok": False, "error": f"Unknown tools on {server['name']}: {', '.join(unknown)}"}
        if not tools:
            return {"ok": False, "error": f"Select at least one tool on {server['name']}, or remove that server."}

    existing = get_agent(name)
    version = next_version(name)
    # A configured model gateway is an access boundary. Failure to validate its
    # group policy must not silently send the agent to a provider directly.
    token = mint_agent_token(name)
    routing = {"ok": False, "detail": "no signing key for the model gateway"}
    if token:
        routing = register_agent_identity(name, spec.get("pools"))
        if not routing["ok"]:
            return {"ok": False, "error": routing["detail"]}
    mcp_token = mint_mcp_token(name) if any(sel.get("tools") for sel in mcp_sel) else ""
    yaml_text = render_yaml({**spec, "name": name, "version": version, "token": token,
                             "mcp_token": mcp_token, "skills": skills})
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rec = {
        "name": name,
        "description": spec.get("description") or name,
        "prompt": prompt,
        "skills": skills,
        "mcp": mcp_sel,
        "yaml": yaml_text,
        "version": version,
        "created": (existing or {}).get("created") or now,
        "updated": now,
        "applied": False,
        "apply_error": None,
        "routed": bool(token),
        "routing": routing,
    }
    store = load_store()
    store["agents"] = [a for a in store["agents"] if a["name"] != name]
    store["agents"].insert(0, rec)
    save_store(store)
    _drop_direct_kagent(name)
    applied = deploy_registry(yaml_text, name)
    rec["applied"] = applied["ok"]
    rec["apply_error"] = applied.get("error")
    rec["apply_text"] = applied.get("text")
    rec["registry"] = {
        "ok": applied["ok"],
        "detail": (applied.get("text") or applied.get("error") or "")[:400],
    }
    rec["platform"] = platform()
    store["agents"][0] = rec
    save_store(store)
    # Auto-approved servers get their grant now, with no one in the loop. Written after the
    # record is saved, because the policy is rebuilt from the store.
    tiers = mcp_tiers(rec)
    rec["auto_granted"] = []
    for sid in tiers["auto"]:
        if sid in GATEWAY_MCP:
            done = _apply_policy(sid)
            if done.returncode == 0:
                rec["auto_granted"].append(sid)
    if rec["auto_granted"]:
        store = load_store()
        store["agents"] = [rec if a["name"] == name else a for a in store["agents"]]
        save_store(store)
    return {"ok": True, "agent": _with_policy(rec)}


def delete_agent(name: str):
    name = slug(name)
    store = load_store()
    store["agents"] = [a for a in store["agents"] if a["name"] != name]
    save_store(store)
    _arctl_login()
    _arctl("delete", "deployment", name)
    _arctl("delete", "agent", name, "--all-tags")
    _arctl("delete", "prompt", f"{name}-prompt", "--all-tags")
    _drop_direct_kagent(name, force=True)
    _apply_all_policies()
    return {"ok": True}


def _drop_direct_kagent(name: str, force: bool = False):
    """Remove a kubectl-applied Declarative Agent so a registry deploy can use the name.

    BYO agents created by AgentRegistry are left in place unless force=True (delete)."""
    raw = kc("-n", NS, "get", "agent", name, "-o", "json", check=False)
    atype = ""
    if raw.returncode == 0 and raw.stdout.strip():
        try:
            atype = (json.loads(raw.stdout).get("spec") or {}).get("type") or ""
        except json.JSONDecodeError:
            atype = ""
    if atype == "BYO" and not force:
        return
    kc("-n", NS, "delete", "agent", name, "--ignore-not-found", check=False)
    kc("-n", NS, "delete", "accesspolicy", f"{name}-invoke", "--ignore-not-found", check=False)
    for m in CATALOG["mcp"]:
        kc("-n", NS, "delete", "remotemcpserver", f"{name}-{m['id']}", "--ignore-not-found", check=False)


def _env_mesh1():
    env = dict(os.environ)
    env["PATH"] = str(Path.home() / ".arctl" / "bin") + ":" + env.get("PATH", "")
    envf = ROOT.parents[0] / "demo-scripts" / "agentregistry" / ".env.mesh1"
    if envf.is_file():
        for line in envf.read_text().splitlines():
            if line.startswith("export ") and "=" in line:
                k, v = line[7:].split("=", 1)
                env[k] = v.strip().strip('"')
    return env


def _arctl(*args, timeout=120):
    env = _env_mesh1()
    env["PATH"] = str(Path.home() / ".arctl" / "bin") + ":" + env.get("PATH", "")
    return subprocess.run(
        ["arctl", *args], env=env, capture_output=True, text=True, timeout=timeout,
    )


def _arctl_login() -> tuple[bool, str]:
    env = _env_mesh1()
    issuer = env.get("KEYCLOAK_ISSUER")
    api = env.get("ARCTL_API_BASE_URL")
    if not issuer or not api:
        return False, "AgentRegistry URL not in .env.mesh1"
    p = _arctl(
        "user", "login",
        "--oidc-flow", "password-credentials",
        "--oidc-issuer-url", issuer,
        "--oidc-client-id", "ar-cli-password",
        "--oidc-username", "admin-user",
        "--oidc-password", "password",
        timeout=30,
    )
    if p.returncode != 0:
        return False, ((p.stderr or p.stdout) or "arctl login failed")[-300:]
    return True, "logged in"


def ensure_image() -> tuple[bool, str]:
    tags = subprocess.run(
        ["curl", "-sf", "http://localhost:5001/v2/my-agents/tags/list"],
        capture_output=True, text=True,
    )
    tag = IMAGE.rsplit(":", 1)[-1]
    if tags.returncode == 0 and tag in (tags.stdout or ""):
        return True, "image ready"
    if not RUNTIME_DIR.is_dir():
        return False, f"agent runtime missing at {RUNTIME_DIR}"
    build = subprocess.run(
        ["docker", "build", "-t", IMAGE, str(RUNTIME_DIR)],
        capture_output=True, text=True, timeout=300,
    )
    if build.returncode != 0:
        return False, (build.stderr or build.stdout or "docker build failed")[-500:]
    push = subprocess.run(
        ["docker", "push", IMAGE], capture_output=True, text=True, timeout=120,
    )
    if push.returncode != 0:
        return False, (push.stderr or push.stdout or "docker push failed")[-500:]
    return True, "image built"


def _ensure_github_standard():
    """My agents select Standard GitHub tools. Token economics may have left the
    shared mcp-demo gateway in Code mode, which only exposes run_code."""
    patch = json.dumps({"spec": {"entMcp": {"toolMode": "Standard"}}})
    kc("-n", "agentgateway-system", "patch", "enterpriseagentgatewaybackend",
       "github-mcp", "--type=merge", "-p", patch, check=False)


def _copy_github_pat():
    raw = kc("-n", "agentgateway-system", "get", "secret", "github-mcp-pat", "-o", "json", check=False)
    if raw.returncode != 0 or not raw.stdout.strip():
        return False
    doc = json.loads(raw.stdout)
    doc["metadata"] = {"name": "github-mcp-pat", "namespace": NS}
    p = subprocess.run(
        ["kubectl", "--context", MESH, "apply", "-f", "-"],
        input=json.dumps(doc), text=True, capture_output=True,
    )
    return p.returncode == 0


def ensure_github_waypoint():
    """Waypoint in kagent so policy sees the agent's ServiceAccount. Default deny."""
    _copy_github_pat()
    kc("apply", "-f", str(GITHUB_WAYPOINT), check=False)
    got = kc("-n", NS, "get", "enterpriseagentgatewaypolicy", GITHUB_POLICY, check=False)
    if got.returncode != 0:
        _apply_github_policy([])


def _tool_aliases(tools, prefix="github"):
    """Gateway may see list_issues; the agent also exposes github_list_issues."""
    out = []
    seen = set()
    pre = prefix + "_"
    for t in tools:
        if not t:
            continue
        base = t.split(".", 1)[-1]
        if base.startswith(pre):
            base = base[len(pre):]
        for alias in (t, base, pre + base):
            if alias and alias not in seen:
                seen.add(alias)
                out.append(alias)
    return out


def _tools_on(rec: dict, sid: str) -> list:
    for mcp in rec.get("mcp") or []:
        if mcp.get("id") == sid:
            return [t for t in (mcp.get("tools") or []) if t]
    return []


def _grants(sid: str, labels: dict | None = None) -> list:
    """Who may call server sid: everyone who asked when it is auto-approved, otherwise only
    the identities a platform admin approved."""
    auto = mcp_auto_approve(sid, labels)
    prefix = registry_mcp_name(sid).replace("-", "_") if sid != "github" else "github"
    grants = []
    for agent in load_store()["agents"]:
        if not (auto or agent.get("mcp_approved") or agent.get("github_approved")):
            continue
        tools = _tool_aliases(_tools_on(agent, sid), prefix)
        if tools:
            grants.append((agent["name"], tools))
    return grants


def _github_grants():
    return _grants("github")


def _policy_yaml(grants, name=None, sid="github"):
    """MCP allow policy. If name is set, only that agent's identity is in the YAML."""
    if name:
        grants = [(sa, tools) for sa, tools in grants if sa == name]
    if not grants:
        expr = "false"
    else:
        clauses = []
        for sa, tools in grants:
            listed = ",\n                 ".join(json.dumps(t) for t in tools)
            clauses.append(
                f'(source.identity.namespace == {json.dumps(NS)}\n'
                f'               && source.identity.serviceAccount == {json.dumps(sa)}\n'
                f'               && jwt.sub == {json.dumps(sa)}\n'
                f'               && mcp.tool.name in [\n'
                f'                 {listed}\n'
                f'               ])'
            )
        expr = "\n            || ".join(clauses)
    expr_indented = "\n".join(
        (line if i == 0 else "            " + line)
        for i, line in enumerate(expr.split("\n"))
    )
    return (
        "apiVersion: enterpriseagentgateway.solo.io/v1alpha1\n"
        "kind: EnterpriseAgentgatewayPolicy\n"
        "metadata:\n"
        f"  name: {GATEWAY_MCP[sid]['policy']}\n"
        f"  namespace: {NS}\n"
        "spec:\n"
        "  targetRefs:\n"
        "  - group: enterpriseagentgateway.solo.io\n"
        "    kind: EnterpriseAgentgatewayBackend\n"
        f"    name: {GATEWAY_MCP[sid]['backend']}\n"
        "  backend:\n"
        "    mcp:\n"
        "      authorization:\n"
        "        action: Allow\n"
        "        policy:\n"
        "          matchExpressions:\n"
        "          - |\n"
        f"            {expr_indented}\n"
    )


def _route_policy_yaml(names, sid: str, only: str | None = None) -> str:
    """Front door for one MCP route: a valid MCP token or 401, and a subject on this
    server's grant list, matching the caller's mesh identity, or 403. No MCP session
    starts for anyone else, so an ungranted agent never even sees an empty tool list."""
    if only:
        names = [n for n in names if n == only]
    if names:
        listed = ", ".join(json.dumps(n) for n in names)
        expr = (f"source.identity.namespace == {json.dumps(NS)}"
                f" && jwt.sub in [{listed}]"
                " && source.identity.serviceAccount == jwt.sub")
    else:
        expr = "false"
    backend = GATEWAY_MCP[sid]["backend"]
    return (
        "apiVersion: enterpriseagentgateway.solo.io/v1alpha1\n"
        "kind: EnterpriseAgentgatewayPolicy\n"
        "metadata:\n"
        f"  name: {backend}-authn\n"
        f"  namespace: {NS}\n"
        "spec:\n"
        "  targetRefs:\n"
        "  - group: gateway.networking.k8s.io\n"
        "    kind: HTTPRoute\n"
        f"    name: {backend}\n"
        "  traffic:\n"
        "    jwtAuthentication:\n"
        "      mode: Strict\n"
        "      providers:\n"
        f"      - issuer: {MCP_ISSUER}\n"
        "        audiences:\n"
        f"        - {MCP_AUDIENCE}\n"
        "        jwks:\n"
        f"          inline: {json.dumps(mcp_jwks() if not only else '<the console MCP key, public half>')}\n"
        "    authorization:\n"
        "      action: Allow\n"
        "      policy:\n"
        "        matchExpressions:\n"
        f"        - {json.dumps(expr)}\n"
    )


def _apply_policy(sid: str, labels: dict | None = None):
    grants = _grants(sid, labels)
    route = subprocess.run(
        ["kubectl", "--context", MESH, "apply", "-f", "-"],
        input=_route_policy_yaml([sa for sa, _ in grants], sid), text=True, capture_output=True,
    )
    if route.returncode != 0:
        return route
    yml = _policy_yaml(grants, sid=sid)
    return subprocess.run(
        ["kubectl", "--context", MESH, "apply", "-f", "-"],
        input=yml, text=True, capture_output=True,
    )


def _apply_github_policy(grants):
    yml = _policy_yaml(grants)
    subprocess.run(
        ["kubectl", "--context", MESH, "apply", "-f", "-"],
        input=yml, text=True, capture_output=True,
    )


def _apply_all_policies():
    labels = registry_mcp_labels(force=True)
    for sid in GATEWAY_MCP:
        if sid == "github":
            ensure_github_waypoint()
        _apply_policy(sid, labels)


def pending_policy_yaml(name: str) -> str:
    """The policy an admin is about to apply for this identity, before they do.

    approved_policy_yaml only answers once the grant exists, which is no use to a
    reviewer deciding whether to make it. This renders the same document from what
    the agent asked for.
    """
    rec = get_agent(name)
    if not rec:
        return ""
    docs = []
    for sid in GATEWAY_MCP:
        if mcp_auto_approve(sid):
            continue
        prefix = registry_mcp_name(sid).replace("-", "_") if sid != "github" else "github"
        tools = _tool_aliases(_tools_on(rec, sid), prefix)
        if tools:
            docs.append(_policy_yaml([(slug(name), tools)], name=slug(name), sid=sid))
    return "---\n".join(docs)


def approved_policy_yaml(name: str) -> str:
    rec = get_agent(name)
    if not rec or not (rec.get("mcp_approved") or rec.get("github_approved")):
        return ""
    docs = []
    for sid in GATEWAY_MCP:
        if mcp_auto_approve(sid) or not _tools_on(rec, sid):
            continue
        docs.append(_policy_yaml(_grants(sid), name=slug(name), sid=sid))
    return "---\n".join(docs)


def auto_policy_yaml(name: str) -> str:
    """The grants written for this identity without anyone approving them."""
    rec = get_agent(name)
    if not rec:
        return ""
    docs = []
    for sid in GATEWAY_MCP:
        if mcp_auto_approve(sid) and _tools_on(rec, sid):
            docs.append(_policy_yaml(_grants(sid), name=slug(name), sid=sid))
    return "---\n".join(docs)


def mcp_tiers(rec: dict) -> dict:
    """Split what an agent asked for into servers it gets straight away and servers that
    wait for a platform admin."""
    labels = registry_mcp_labels()
    auto, restricted = [], []
    for m in requested_mcp(rec):
        (auto if mcp_auto_approve(m["id"], labels) else restricted).append(m["id"])
    return {"auto": auto, "restricted": restricted}


def requested_mcp(rec: dict) -> list:
    out = []
    for mcp in rec.get("mcp") or []:
        tools = [t for t in (mcp.get("tools") or []) if t]
        if tools:
            out.append({"id": mcp.get("id"), "tools": tools})
    return out


def mcp_is_approved(rec: dict) -> bool:
    """True when nothing is left for an admin: approved, or only auto-approved servers asked for."""
    if rec.get("mcp_approved") or rec.get("github_approved"):
        return True
    return not mcp_tiers(rec)["restricted"]


# Approve and revoke both rewrite the whole policy from the store, so two at
# once would drop one of the grants.
_GRANT_LOCK = threading.Lock()


def approve_github(name: str):
    """Admin grant: this identity may call the MCP tools it requested."""
    with _GRANT_LOCK:
        return _approve_github(name)


def _approve_github(name: str):
    name = slug(name)
    rec = get_agent(name)
    if not rec:
        return {"ok": False, "error": "unknown agent"}
    asked = requested_mcp(rec)
    if not asked:
        return {"ok": False, "error": "this agent has no MCP tools selected"}
    gh_tools = next((m["tools"] for m in asked if m["id"] == "github"), [])
    rec["mcp_approved"] = True
    rec["github_approved"] = True
    store = load_store()
    store["agents"] = [rec if a["name"] == name else a for a in store["agents"]]
    save_store(store)
    _apply_all_policies()
    probe = {"ok": True, "allowed": True, "detail": "approved"}
    if gh_tools:
        time.sleep(2)
        probe = _probe_github(name)
    rec["github_probe"] = probe
    store = load_store()
    store["agents"] = [rec if a["name"] == name else a for a in store["agents"]]
    save_store(store)
    return {"ok": True, "serviceAccount": name, "mcp": asked, "probe": probe}


def revoke_github(name: str):
    """Admin revoke: drop this identity from the waypoint allow list."""
    with _GRANT_LOCK:
        return _revoke_github(name)


def _revoke_github(name: str):
    name = slug(name)
    rec = get_agent(name)
    if not rec:
        return {"ok": False, "error": "unknown agent"}
    rec["mcp_approved"] = False
    rec["github_approved"] = False
    store = load_store()
    store["agents"] = [rec if a["name"] == name else a for a in store["agents"]]
    save_store(store)
    _apply_all_policies()
    time.sleep(2)
    probe = _probe_github(name)
    rec["github_probe"] = probe
    store = load_store()
    store["agents"] = [rec if a["name"] == name else a for a in store["agents"]]
    save_store(store)
    return {"ok": True, "revoked": True, "serviceAccount": name, "probe": probe}


def _probe_github(name: str) -> dict:
    """Call list_issues from the agent pod so the demo can show allow vs deny."""
    return _probe_mcp(name, "github", "list_issues",
                      {"owner": "tjorourke", "repo": "network-slice-manager", "state": "open"})


def _probe_mcp(name: str, sid: str, tool: str, args: dict) -> dict:
    """Call one tool from the agent pod, as the agent's own identity, through the gateway."""
    server = next((m for m in CATALOG["mcp"] if m["id"] == sid), {})
    target = server.get("url") or ""
    script = (
        "import os,json,urllib.request\n"
        f"url={json.dumps(target)}\n"
        "def post(p,sid=None):\n"
        "  d=json.dumps(p).encode()\n"
        "  h={'content-type':'application/json','accept':'application/json, text/event-stream'}\n"
        "  if os.environ.get('MCP_TOKEN'): h['authorization']='Bearer '+os.environ['MCP_TOKEN']\n"
        "  if sid: h['mcp-session-id']=sid\n"
        "  req=urllib.request.Request(url,data=d,headers=h,method='POST')\n"
        "  try:\n"
        "    r=urllib.request.urlopen(req,timeout=20)\n"
        "    return r.status,{k.lower():v for k,v in r.headers.items()},r.read()\n"
        "  except Exception as e:\n"
        "    b=e.read() if hasattr(e,'read') else str(e).encode()\n"
        "    return getattr(e,'code',None),{},b\n"
        "st,h,b=post({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'probe','version':'0'}}})\n"
        "sid=h.get('mcp-session-id')\n"
        f"st2,h2,b2=post({{'jsonrpc':'2.0','id':2,'method':'tools/call','params':{{'name':{json.dumps(tool)},'arguments':{json.dumps(args)}}}}},sid)\n"
        "txt=(b2 or b).decode('utf-8','replace')[:500]\n"
        "print(json.dumps({'http':st2 or st,'body':txt}))\n"
    )
    p = subprocess.run(
        ["kubectl", "--context", MESH, "-n", NS, "exec", f"deploy/{name}", "--",
         "python3", "-c", script],
        capture_output=True, text=True, timeout=40,
    )
    line = (p.stdout or "").strip().splitlines()[-1] if (p.stdout or "").strip() else ""
    try:
        out = json.loads(line)
    except json.JSONDecodeError:
        return {"ok": False, "detail": (p.stderr or p.stdout or "probe failed")[-300:]}
    body = out.get("body") or ""
    # Streamable HTTP answers as JSON or as SSE; the JSON-RPC message is the
    # last data: line. A result is an allowed call even when it is empty.
    msg = body
    for line in body.splitlines():
        if line.startswith("data:"):
            msg = line[5:].strip()
    try:
        rpc = json.loads(msg)
    except json.JSONDecodeError:
        rpc = None
    http = int(out.get("http") or 0)
    if isinstance(rpc, dict) and "result" in rpc and http < 400:
        res = rpc.get("result") or {}
        if not res.get("isError"):
            return {"ok": True, "allowed": True, "detail": f"{tool} succeeded",
                    "text": " ".join(c.get("text", "") for c in res.get("content") or [] if isinstance(c, dict))[:400]}
        text = " ".join(c.get("text", "") for c in res.get("content") or [] if isinstance(c, dict))
        return {"ok": True, "allowed": False, "detail": text[:280] or "tool returned an error"}
    if isinstance(rpc, dict) and "error" in rpc:
        return {"ok": True, "allowed": False, "detail": str((rpc.get("error") or {}).get("message") or rpc["error"])[:280]}
    return {"ok": True, "allowed": False, "detail": body[:280] or f"http {out.get('http')}"}


def github_approved(name: str) -> bool:
    rec = get_agent(name) or {}
    return mcp_is_approved(rec)


def deploy_registry(yaml_text: str, name: str) -> dict:
    """Publish Prompt, MCP, Agent and Deployment through arctl. Never kubectl the Agent."""
    ok, detail = _arctl_login()
    if not ok:
        return {"ok": False, "error": detail}
    img_ok, img_detail = ensure_image()
    if not img_ok:
        return {"ok": False, "error": img_detail}
    _ensure_github_standard()
    ensure_registry_mcps()
    if "name: github\n" in yaml_text:
        ensure_github_waypoint()
    stack = DATA / "tmp-stack.yaml"
    DATA.mkdir(parents=True, exist_ok=True)
    stack.write_text(yaml_text)
    applied = _arctl("apply", "-f", str(stack), timeout=60)
    text = ((applied.stdout or "") + (applied.stderr or "")).strip()
    if applied.returncode != 0:
        return {"ok": False, "error": text[-800:] or "arctl apply failed", "text": text[-800:]}
    waited = _arctl("wait", "deployment", name, "--timeout", "3m", timeout=200)
    wait_text = ((waited.stdout or "") + (waited.stderr or "")).strip()
    if waited.returncode != 0:
        return {
            "ok": False,
            "error": (wait_text or "deployment did not become ready")[-800:],
            "text": (text + "\n" + wait_text)[-800:],
        }
    return {"ok": True, "text": (text + "\n" + wait_text)[-800:]}


def agent_status(name: str) -> dict:
    name = slug(name)
    rec = get_agent(name) or {"name": name}
    plat = platform()
    steps = []
    steps.append({
        "id": "saved", "label": "Saved",
        "state": "done" if rec.get("yaml") else "wait",
        "detail": rec.get("created") or "",
    })
    reg = rec.get("registry") or {}
    in_catalog = False
    catalog_detail = (reg.get("detail") or "")[:240]
    listed = _arctl("get", "agent", name, timeout=15)
    if listed.returncode == 0:
        in_catalog = True
        catalog_detail = catalog_detail or "Agent is in the catalog."
    elif rec.get("yaml") and not rec.get("applied"):
        catalog_detail = catalog_detail or "Waiting to publish."
    steps.append({
        "id": "registry", "label": "Registry",
        "state": "done" if (in_catalog or reg.get("ok")) else ("fail" if rec.get("apply_error") else "wait"),
        "detail": catalog_detail or "Publish the Agent, then deploy it onto kagent.",
    })
    uses_mcp = bool(requested_mcp(rec))
    if uses_mcp:
        tiers = mcp_tiers(rec)
        names = {m["id"]: m["name"] for m in CATALOG["mcp"]}
        auto_names = ", ".join(names.get(i, i) for i in tiers["auto"])
        admin = bool(rec.get("mcp_approved") or rec.get("github_approved"))
        granted = admin or not tiers["restricted"]
        parts = []
        if tiers["auto"]:
            parts.append(f"{auto_names}: allowed automatically, its AgentRegistry record is labelled {AUTO_APPROVE_LABEL}=true.")
        if tiers["restricted"]:
            rnames = ", ".join(names.get(i, i) for i in tiers["restricted"])
            parts.append(f"{rnames}: approved by a platform admin." if admin
                         else f"{rnames}: default deny until a platform admin approves.")
        steps.append({
            "id": "mcp", "label": "MCP access",
            "state": "done" if granted else "wait",
            "detail": " ".join(parts),
        })
    accepted = ready = False
    kmsg = ""
    raw = kc("-n", NS, "get", "agent", name, "-o", "json", check=False)
    if raw.returncode == 0 and raw.stdout.strip():
        try:
            obj = json.loads(raw.stdout)
            atype = (obj.get("spec") or {}).get("type") or ""
            if atype and atype != "BYO":
                kmsg = "This kagent Agent was applied direct. Delete it and deploy again through the registry."
            else:
                st = obj.get("status") or {}
                for c in st.get("conditions") or []:
                    if c.get("type") == "Accepted" and c.get("status") == "True":
                        accepted = True
                        kmsg = c.get("message") or "Accepted"
                    if c.get("type") == "Ready" and c.get("status") == "True":
                        ready = True
                        kmsg = c.get("message") or "Ready"
                    elif c.get("type") == "Ready":
                        kmsg = c.get("message") or kmsg
        except json.JSONDecodeError:
            kmsg = "could not parse agent status"
    elif rec.get("applied"):
        kmsg = rec.get("apply_error") or "waiting for the runtime to create the kagent Agent"
    else:
        kmsg = rec.get("apply_error") or "not deployed"
    if ready:
        kstate = "done"
    elif accepted:
        kstate = "wait"
    elif rec.get("applied"):
        kstate = "wait"
    else:
        kstate = "fail" if rec.get("apply_error") else "wait"
    steps.append({
        "id": "kagent", "label": "kagent",
        "state": kstate,
        "detail": kmsg[:240],
    })
    steps.append({
        "id": "ready", "label": "Ready to prompt",
        "state": "done" if ready else "wait",
        "detail": "Open kagent and talk to it." if ready else "Waiting for the pod.",
    })
    logs = kc("-n", NS, "logs", f"deploy/{name}", "--tail=40", check=False)
    log_text = (logs.stdout or logs.stderr or "")[-4000:]
    k_ui = (plat.get("ui") or "").rstrip("/")
    r_ui = (plat.get("registry_ui") or "").rstrip("/")
    return {
        "name": name,
        "steps": steps,
        "ready": ready,
        "logs": log_text,
        "urls": {
            "kagent": k_ui + "/agents" if k_ui else "",
            "registry": r_ui or "",
            "prompt": (k_ui + "/agents/" + name) if k_ui else "",
        },
        "agent": _with_policy(rec),
        "platform": plat,
    }
