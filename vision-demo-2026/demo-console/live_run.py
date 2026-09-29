#!/usr/bin/env python3
"""Live GitHub MCP run through mesh1 agentgateway, with a real model loop.

MCP tools go through the gateway (PAT stays in the cluster). The model is
Claude; each turn's usage.input_tokens / output_tokens is what we bill.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CTX = os.environ.get("MESH_CONTEXT", "kind-mesh1")
NS = "agentgateway-system"
REPO = os.environ.get("DEMO_REPO", "tjorourke/network-slice-manager")
SECRETS = Path(os.environ.get("SECRETS_FILE", ROOT.parent / "secrets.env"))
RATES = {"input_per_m": 3.0, "output_per_m": 15.0}
MODEL = os.environ.get("DEMO_MODEL", "claude-sonnet-5")
MODE_MAP = {"standard": "Standard", "code": "CodeSearch"}
# Published to AgentRegistry by agents_lab.ensure_prompts() with the other packaged prompts.
PROMPTS = ROOT.parent / "demo-scripts" / "agentregistry" / "prompt"
PROMPT_FILES = {"standard": "release-report.yaml", "code": "release-report-code-mode.yaml"}


def kubectl(*args, check=True):
    return subprocess.run(
        ["kubectl", "--context", CTX, *args],
        check=check, text=True, capture_output=True,
    )


def secrets():
    if not SECRETS.is_file():
        raise SystemExit(f"missing {SECRETS}")
    script = (
        f'set -a; . "{SECRETS}"; set +a; '
        'python3 -c "import os,json; print(json.dumps({'
        '\\"GITHUB_PAT\\": os.environ.get(\\"GITHUB_PORTLAB_TOKEN\\") or os.environ.get(\\"GITHUB_PAT\\") or \\"\\",'
        '\\"ANTHROPIC_API_KEY\\": os.environ.get(\\"ANTHROPIC_API_KEY\\") or \\"\\"'
        '}))"'
    )
    out = subprocess.check_output(["bash", "-lc", script], text=True)
    env = json.loads(out)
    if not env.get("GITHUB_PAT"):
        raise SystemExit("GITHUB_PORTLAB_TOKEN / GITHUB_PAT not set")
    if not env.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY not set")
    return env


def ensure():
    env = secrets()
    secret = subprocess.check_output(
        ["kubectl", "--context", CTX, "-n", NS, "create", "secret", "generic",
         "github-mcp-pat", f"--from-literal=Authorization={env['GITHUB_PAT']}",
         "--dry-run=client", "-o", "yaml"],
    )
    subprocess.run(
        ["kubectl", "--context", CTX, "apply", "-f", "-"],
        input=secret, check=True,
    )
    subprocess.run(
        ["kubectl", "--context", CTX, "apply", "-f", str(ROOT / "yaml" / "github-mcp.yaml")],
        check=True, capture_output=True,
    )
    for _ in range(30):
        st = kubectl(
            "-n", NS, "get", "enterpriseagentgatewaybackend", "github-mcp",
            "-o", "jsonpath={.status.conditions[?(@.type=='Accepted')].status}",
            check=False,
        ).stdout.strip()
        gw = kubectl(
            "-n", NS, "get", "gateway", "mcp-demo",
            "-o", "jsonpath={.status.addresses[0].value}",
            check=False,
        ).stdout.strip()
        if st == "True" and gw:
            return {"ip": gw, "anthropic": env["ANTHROPIC_API_KEY"]}
        time.sleep(2)
    raise SystemExit("github-mcp backend or mcp-demo gateway did not become ready")


def set_mode(mode: str):
    field = MODE_MAP[mode]
    kubectl(
        "-n", NS, "patch", "enterpriseagentgatewaybackend", "github-mcp",
        "--type=merge", "-p", json.dumps({"spec": {"entMcp": {"toolMode": field}}}),
    )


class Mcp:
    def __init__(self, url: str):
        self.url = url if url.endswith("/") else url + "/"
        self.session = None
        self.n = 0
        self.call("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "token-economics", "version": "1"},
        })
        self.notify("notifications/initialized")

    def notify(self, method, params=None):
        self._post({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def call(self, method, params=None):
        self.n += 1
        return self._post({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}})

    def _post(self, payload):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, json.dumps(payload).encode(), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                sid = r.headers.get("Mcp-Session-Id")
                if sid:
                    self.session = sid
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"MCP HTTP {e.code}: {e.read()[:400].decode('utf-8', 'replace')}") from e
        text = raw
        if "data: " in raw:
            chunks = [ln[6:] for ln in raw.splitlines() if ln.startswith("data: ")]
            text = "".join(chunks)
        if not text.strip():
            return {}
        data = json.loads(text)
        if data.get("error"):
            raise RuntimeError(f"MCP {payload.get('method')}: {data['error']}")
        return data.get("result", data)

    def tools(self):
        out = []
        cursor = None
        while True:
            params = {"cursor": cursor} if cursor else {}
            res = self.call("tools/list", params or None)
            out.extend(res.get("tools") or [])
            cursor = res.get("nextCursor")
            if not cursor:
                break
        return out

    def invoke(self, name, arguments=None):
        return self.call("tools/call", {"name": name, "arguments": arguments or {}})


def parse_tool_text(result):
    content = result.get("content") or []
    parts = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "text":
            parts.append(c.get("text") or "")
        elif isinstance(c, str):
            parts.append(c)
    return "\n".join(parts)[:80000]


def anthropic(api_key, messages, tools, system=None):
    body = {
        "model": MODEL,
        "max_tokens": 4096,
        "messages": messages,
        "tools": tools,
    }
    if system:
        body["system"] = system
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        json.dumps(body).encode(),
        {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Anthropic HTTP {e.code}: {e.read()[:600].decode('utf-8', 'replace')}") from e


def to_anthropic_tools(mcp_tools):
    out = []
    for t in mcp_tools:
        schema = t.get("inputSchema") or t.get("input_schema") or {"type": "object", "properties": {}}
        out.append({
            "name": t["name"],
            "description": (t.get("description") or t["name"])[:1024],
            "input_schema": schema,
        })
    return out


def usd(tin, tout):
    return tin * RATES["input_per_m"] / 1e6 + tout * RATES["output_per_m"] / 1e6


def classify_prs(rows):
    items = []
    for p in rows or []:
        if not isinstance(p, dict):
            continue
        labels = []
        for lab in p.get("labels") or []:
            labels.append(lab.get("name") if isinstance(lab, dict) else str(lab))
        n = p.get("n") or p.get("number")
        items.append({
            "n": n,
            "title": p.get("title") or "",
            "labels": labels,
            "url": p.get("html_url") or p.get("url") or f"https://github.com/{REPO}/pull/{n}",
        })
    groups = {
        "ready": {"id": "ready", "label": "Ready to merge", "items": []},
        "work": {"id": "work", "label": "Needs work", "items": []},
        "block": {"id": "block", "label": "Do not merge", "items": []},
    }
    for it in items:
        labs = set(it.get("labels") or [])
        bucket = "work"
        if "do-not-merge" in labs:
            bucket = "block"
        elif "ready-to-merge" in labs:
            bucket = "ready"
        note = next((l.replace("-", " ") for l in it["labels"]
                     if l not in ("ready-to-merge", "needs-work", "do-not-merge")), "")
        groups[bucket]["items"].append({
            "n": it["n"], "title": it["title"], "note": note, "url": it["url"],
        })
    return {
        "title": "Release report",
        "repo": REPO,
        "open": len(items),
        "groups": [groups["ready"], groups["work"], groups["block"]],
    }


def report_from_github(mcp: Mcp, tools):
    names = {t["name"] for t in tools}
    owner, name = REPO.split("/", 1)
    args = {"owner": owner, "repo": name, "state": "open", "perPage": 50,
            "fields": ["number", "title", "labels", "html_url", "draft"]}
    if "list_pull_requests" in names:
        raw = parse_tool_text(mcp.invoke("list_pull_requests", args))
    elif "run_code" in names:
        # CodeSearch serves only get_tool and run_code, so the GitHub tool is called
        # from inside a script. The script's last expression is the result, wrapped
        # in {"success": ...}.
        raw = parse_tool_text(mcp.invoke("run_code", {
            "code": f"await list_pull_requests({json.dumps(args)})"}))
    else:
        return classify_prs([])
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = []
    if isinstance(data, dict):
        data = (data.get("success") or data.get("pullRequests") or data.get("items")
                or data.get("prs") or [])
    return classify_prs(data)


_TOOLS_CACHE = {"standard": None, "code": None, "at": 0}


def list_mode_tools(mode: str):
    """Live tools/list for the economy page, before anyone clicks Run."""
    now = time.time()
    cached = _TOOLS_CACHE.get(mode)
    if cached and now - _TOOLS_CACHE["at"] < 180:
        return cached
    info = ensure()
    set_mode(mode)
    mcp, names = wait_mode(f"http://{info['ip']}/", mode)
    tools = mcp.tools()
    names = sorted({t["name"] for t in tools})
    _TOOLS_CACHE[mode] = names
    _TOOLS_CACHE["at"] = now
    return names


def wait_mode(mcp_url, mode, tries=20):
    want = MODE_MAP[mode]
    for i in range(tries):
        try:
            mcp = Mcp(mcp_url)
            names = [t["name"] for t in mcp.tools()]
        except Exception:
            time.sleep(2)
            continue
        has_run = "run_code" in names
        has_get = "get_tool" in names
        ok = (want == "Standard" and not has_run and not has_get and names) or \
             (want == "Code" and has_run and not has_get) or \
             (want == "CodeSearch" and has_run and has_get)
        if ok:
            return mcp, names
        time.sleep(2)
    raise RuntimeError(f"gateway never served {want}")


def emit_metrics(emit, t0, loops, tin, tout, source):
    elapsed = int((time.time() - t0) * 1000)
    emit({
        "type": "metrics",
        "loops": loops,
        "tokens_in": tin,
        "tokens_out": tout,
        "tokens": tin + tout,
        "ms": elapsed,
        "usd": round(usd(tin, tout), 4),
        "token_source": source,
    })


def mcp_scripted(mode, mcp, tools, emit, t0):
    """Live MCP through the gateway when the model key is not usable.

    Tokens are payload bytes / 4 plus the tool schema, billed at Sonnet rates.
    """
    owner, name = REPO.split("/", 1)
    schema = len(json.dumps(tools))
    payload = 0
    loops = 0
    source = "payload"

    def call(tool_name, args, title=None):
        nonlocal payload, loops
        emit({"type": "step", "title": title or tool_name, "detail": json.dumps(args)[:180]})
        res = mcp.invoke(tool_name, args)
        text = parse_tool_text(res) or json.dumps(res)
        payload += len(text)
        loops += 1
        tin = (schema + payload) // 4
        emit_metrics(emit, t0, loops, tin, 0, source)
        return text

    names = {t["name"] for t in tools}
    report_rows = []
    if mode == "code" and "run_code" in names:
        prog = (
            'const prs = await list_pull_requests({owner:"%s",repo:"%s",state:"open",perPage:50,'
            'fields:["number","title","labels","html_url","draft"]});\n'
            'prs.map(p => ({n:p.number,title:p.title,labels:(p.labels||[]).map(l => l.name||l),html_url:p.html_url}));'
            % (owner, name)
        )
        raw = call("run_code", {"code": prog}, "run_code")
        try:
            data = json.loads(raw)
            if isinstance(data, dict) and "success" in data:
                data = data["success"]
            report_rows = data if isinstance(data, list) else []
        except json.JSONDecodeError:
            report_rows = []
    else:
        raw = call("list_pull_requests", {
            "owner": owner, "repo": name, "state": "open", "perPage": 50,
            "fields": ["number", "title", "labels", "html_url", "draft"],
        })
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = []
        if isinstance(data, dict):
            data = data.get("pullRequests") or data.get("items") or []
        report_rows = data or []
        if "pull_request_read" in names:
            for p in report_rows:
                n = p.get("number") or p.get("n")
                if not n:
                    continue
                try:
                    call("pull_request_read", {
                        "owner": owner, "repo": name, "pullNumber": n, "method": "get_status",
                    }, f"pull_request_read #{n}")
                except Exception as e:
                    emit({"type": "step", "title": f"pull_request_read #{n}", "detail": str(e)[:180]})
    tin = (schema + payload) // 4
    return classify_prs(report_rows), loops, tin, 0, source


def system_prompt(mode: str) -> str:
    """The run's system prompt, read from the Prompt published to AgentRegistry, so the
    economy page and anything that pulls the prompt from the registry say the same thing.

    The code-mode prompt spends its extra lines on the errors the model otherwise loops
    on: looking up signatures it already has, reading run_code's {"success": ...}
    wrapper as the tool's return shape, assigning to an undeclared `result` because the
    tool description says to, and one list plus 24 status reads going over the
    gateway's 20-call cap per script.
    """
    import yaml
    doc = yaml.safe_load((PROMPTS / PROMPT_FILES[mode]).read_text())
    text = doc["spec"]["content"].strip()
    owner, name = REPO.split("/", 1)
    return (text.replace("tjorourke/network-slice-manager", REPO)
                .replace('"tjorourke"', f'"{owner}"')
                .replace('"network-slice-manager"', f'"{name}"'))


def run(mode: str, prompt: str, emit):
    t0 = time.time()
    emit({"type": "status", "text": "attaching GitHub MCP on mesh1"})
    info = ensure()
    mcp_url = f"http://{info['ip']}/"
    emit({"type": "status", "text": f"gateway {info['ip']}  toolMode {MODE_MAP[mode]}"})
    set_mode(mode)
    mcp, names = wait_mode(mcp_url, mode)
    tools = mcp.tools()
    emit({
        "type": "tools",
        "count": len(tools),
        "names": [t["name"] for t in tools],
        "write": [t["name"] for t in tools if any(x in t["name"] for x in
                  ("create", "update", "delete", "merge", "push", "fork", "star"))],
    })
    source = "model"
    loops = tin = tout = 0
    report = None
    try:
        system = system_prompt(mode)
        messages = [{"role": "user", "content": prompt}]
        a_tools = to_anthropic_tools(tools)
        for _ in range(24):
            msg = anthropic(info["anthropic"], messages, a_tools, system=system)
            usage = msg.get("usage") or {}
            tin += int(usage.get("input_tokens") or 0)
            tout += int(usage.get("output_tokens") or 0)
            content = msg.get("content") or []
            tool_uses = [b for b in content if b.get("type") == "tool_use"]
            emit_metrics(emit, t0, loops, tin, tout, source)
            if not tool_uses:
                break
            tool_results = []
            for tu in tool_uses:
                loops += 1
                name = tu.get("name")
                args = tu.get("input") or {}
                emit({"type": "step", "title": name, "detail": json.dumps(args)[:180]})
                try:
                    result = mcp.invoke(name, args)
                    text = parse_tool_text(result) or json.dumps(result)[:8000]
                except Exception as e:
                    text = f"tool error: {e}"
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tu["id"],
                    "content": text[:20000],
                })
            messages.append({"role": "assistant", "content": content})
            messages.append({"role": "user", "content": tool_results})
            emit_metrics(emit, t0, loops, tin, tout, source)
        emit({"type": "status", "text": "reading open pull requests from the gateway"})
        report = report_from_github(mcp, tools)
    except Exception as e:
        msg = str(e)
        if "401" in msg:
            msg = "Anthropic key on this cluster is not accepted. Measuring live MCP payload instead."
        else:
            msg = f"model loop unavailable. Measuring live MCP payload instead. ({msg[:120]})"
        emit({"type": "status", "text": msg})
        report, loops, tin, tout, source = mcp_scripted(mode, mcp, tools, emit, t0)
    emit({"type": "report", "report": report})
    elapsed = int((time.time() - t0) * 1000)
    emit({
        "type": "done",
        "live": True,
        "loops": loops,
        "tokens_in": tin,
        "tokens_out": tout,
        "tokens": tin + tout,
        "ms": elapsed,
        "usd": round(usd(tin, tout), 4),
        "tools": len(tools),
        "token_source": source,
    })


def main():
    import sys
    mode = sys.argv[1] if len(sys.argv) > 1 else "standard"
    prompt = sys.argv[2] if len(sys.argv) > 2 else f"Give me the release report for {REPO}, all open pull requests."

    def emit(ev):
        print(json.dumps(ev), flush=True)

    run(mode, prompt, emit)


if __name__ == "__main__":
    main()
