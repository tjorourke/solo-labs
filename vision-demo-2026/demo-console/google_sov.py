"""Google Sovereign Cloud: the Berlin GCD agentgateway, from the console.

Two routes behind one gateway, chosen by vLLM Semantic Router (VSR) as an
extProc at PreRouting. agw.* is a ListenerSet on the one agentgateway-proxy, so
the router sees model traffic only:

    gemma   Gemma 3 27B on an H100 inside the cluster. Never leaves Berlin.
    gemini  Gemini 2.5 Flash, Google's frontier model, out through Cloud NAT.

The gateway is reached the first way that works, in this order:

    1. GCD_AGW_URL, if set (a tunnel, anything).
    2. http://agw.agentic.eu0.internal, when that name resolves on this laptop
       (./scripts/hosts.sh in google-sov writes it). The fixed hostname the demo
       is meant to show.
    3. The agentgateway-proxy-external LoadBalancer IP, looked up with kubectl,
       with the Host header set (80-ingress.sh EXPOSE_EXTERNAL=1 creates it).
    4. A kubectl port-forward to the gateway Service, using the Berlin kubeconfig.

    GCD_AGW_URL       e.g. http://34.x.x.x  (unset: try 2-4)
    GCD_LLM_HOST      Host header the HTTPRoute matches (agw.agentic.eu0.internal)
    GCD_KUBECONFIG    ~/code/google-sov/poc/2026-09-agentic-platform/deploy/.kubeconfig
    GCD_UNIVERSE      apis-berlin-build0.goog
    GCD_AGW_NS        agentgateway-system
    GCD_AGW_GATEWAY   agentgateway-proxy
    GCD_PF_PORT       18090 (a free port is picked if it is taken)
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

LLM_HOST = os.environ.get("GCD_LLM_HOST", "agw.agentic.eu0.internal")
KUBECONFIG = os.path.expanduser(os.environ.get(
    "GCD_KUBECONFIG", "~/code/google-sov/poc/2026-09-agentic-platform/deploy/.kubeconfig"))
UNIVERSE = os.environ.get("GCD_UNIVERSE", "apis-berlin-build0.goog")
NS = os.environ.get("GCD_AGW_NS", "agentgateway-system")
GATEWAY = os.environ.get("GCD_AGW_GATEWAY", "agentgateway-proxy")
PF_PORT = int(os.environ.get("GCD_PF_PORT", "18090"))
EXTERNAL_SVC = os.environ.get("GCD_AGW_EXTERNAL_SVC", "agentgateway-proxy-external")

# What the console sends per route. "auto" lets VSR classify the prompt; an
# explicit route names the model AND sets the header the HTTPRoute matches, so
# the choice holds even if the router is down (the policy fails open).
ROUTES = {
    "auto": {"model": "auto", "header": None},
    "gemma": {"model": "gemma-3-27b-it", "header": "gemma-3-27b-it"},
    "gemini": {"model": "gemini-2.5-flash", "header": "gemini-2.5-flash"},
}

_pf_lock = threading.Lock()
_pf: subprocess.Popen | None = None
_pf_port = PF_PORT


def _env() -> dict:
    env = dict(os.environ)
    env["KUBECONFIG"] = KUBECONFIG
    env["GOOGLE_CLOUD_UNIVERSE_DOMAIN"] = UNIVERSE
    return env


def _kubectl(*args: str, timeout: int = 20) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", *args], env=_env(), capture_output=True,
                          text=True, timeout=timeout)


def _gateway_service() -> str:
    r = _kubectl("-n", NS, "get", "svc", "-l", f"gateway.networking.k8s.io/gateway-name={GATEWAY}",
                 "-o", "jsonpath={.items[*].metadata.name}")
    names = [n for n in r.stdout.split() if n != EXTERNAL_SVC]
    if r.returncode != 0:
        raise RuntimeError(_auth_hint(r.stderr) or f"cannot list Services in {NS}")
    if not names:
        raise RuntimeError(f"Gateway {NS}/{GATEWAY} is not deployed yet: run ./scripts/80-ingress.sh in google-sov")
    return names[0]


def _auth_hint(stderr: str) -> str:
    s = stderr or ""
    if "Refresh token has expired" in s or "reauth" in s.lower() or "credential" in s.lower():
        return "Berlin credentials expired: run ./scripts/gcd-auth.sh in ~/code/google-sov"
    return s.strip().splitlines()[-1][:200] if s.strip() else ""


def _probe(url: str) -> str | None:
    """'ok' when the agw.* models route answers at url, 'no-route' when the
    gateway answers but has no such route, None when nothing answers. Any HTTP
    answer from the route counts (a GET on the chat path draws a 405 from the
    model, or a 503 with no backend), but "route not found" means the gateway is
    up and the models route is not: 87-vsr-routes.sh has not run."""
    req = urllib.request.Request(url + "/v1/chat/completions",
                                 headers={"Host": LLM_HOST, "x-selected-model": ROUTES["gemma"]["header"]})
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            body = r.read(200)
    except urllib.error.HTTPError as e:
        body = e.read(200)
    except Exception:
        return None
    return "no-route" if b"route not found" in body else "ok"


def _reachable(url: str) -> bool:
    return _probe(url) == "ok"


def _no_route(where: str) -> RuntimeError:
    return RuntimeError(f"agentgateway answers at {where} but has no route for {LLM_HOST}: "
                        "run ./scripts/87-vsr-routes.sh in google-sov")


def _port_free(port: int) -> bool:
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _resolves_publicly(host: str) -> bool:
    """True when the name resolves to an address a laptop can route to. A private
    answer (an old in-VPC entry, a stale hosts line) would just hang."""
    try:
        ip = socket.gethostbyname(host)
    except OSError:
        return False
    a, b = (int(x) for x in ip.split(".")[:2])
    return not (a == 10 or a == 127 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168))


def _external_ip() -> str:
    r = _kubectl("-n", NS, "get", "svc", EXTERNAL_SVC,
                 "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}", timeout=10)
    return r.stdout.strip() if r.returncode == 0 else ""


def base_url() -> tuple[str, str]:
    """(url, how) — how is 'configured', 'hostname', 'external-lb' or 'port-forward'."""
    if os.environ.get("GCD_AGW_URL"):
        return os.environ["GCD_AGW_URL"].rstrip("/"), "configured"
    if _resolves_publicly(LLM_HOST):
        url = f"http://{LLM_HOST}"
        p = _probe(url)
        if p == "ok":
            return url, "hostname"
        if p == "no-route":
            # The gateway is reachable; a port-forward to it would say the same.
            raise _no_route(url)
    ip = _external_ip()
    if ip:
        p = _probe(f"http://{ip}")
        if p == "ok":
            return f"http://{ip}", "external-lb"
        if p == "no-route":
            raise _no_route(f"http://{ip}")
    global _pf, _pf_port
    with _pf_lock:
        if _pf is not None and _pf.poll() is None and _reachable(f"http://127.0.0.1:{_pf_port}"):
            return f"http://127.0.0.1:{_pf_port}", "port-forward"
        if _pf is not None:
            _pf.kill()
            _pf = None
        # A forward left behind by an earlier console run (pkill -f serve.py does
        # not take its kubectl child with it) still works: use it.
        if not _port_free(PF_PORT):
            p = _probe(f"http://127.0.0.1:{PF_PORT}")
            if p == "ok":
                return f"http://127.0.0.1:{PF_PORT}", "port-forward"
            if p == "no-route":
                raise _no_route(f"127.0.0.1:{PF_PORT}")
        _pf_port = PF_PORT if _port_free(PF_PORT) else _free_port()
        url = f"http://127.0.0.1:{_pf_port}"
        svc = _gateway_service()
        _pf = subprocess.Popen(["kubectl", "-n", NS, "port-forward", f"svc/{svc}", f"{_pf_port}:80"],
                               env=_env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        for _ in range(40):
            if _pf.poll() is not None:
                err = _pf.stderr.read() if _pf.stderr else ""
                _pf = None
                raise RuntimeError(_auth_hint(err) or "port-forward exited")
            p = _probe(url)
            if p == "ok":
                return url, "port-forward"
            if p == "no-route":
                raise _no_route(f"svc/{svc}")
            time.sleep(0.25)
        raise RuntimeError(f"port-forward to svc/{svc} did not come up")


def _pods(selector: str) -> list[dict]:
    r = _kubectl("-n", NS, "get", "pods", "-l", selector, "-o", "json")
    if r.returncode != 0:
        return []
    out = []
    for p in json.loads(r.stdout).get("items", []):
        cs = p.get("status", {}).get("containerStatuses", [])
        out.append({"name": p["metadata"]["name"],
                    "ready": bool(cs) and all(c.get("ready") for c in cs),
                    "phase": p.get("status", {}).get("phase"),
                    "company": p["metadata"].get("labels", {}).get("company", "")})
    return out


def status() -> dict:
    """What is deployed in Berlin, and whether the console can reach it."""
    s: dict = {"host": LLM_HOST, "namespace": NS, "gateway": GATEWAY, "universe": UNIVERSE}
    try:
        s["url"], s["via"] = base_url()
        s["reachable"] = True
    except Exception as e:
        s["reachable"] = False
        s["error"] = str(e)
        return s
    s["gateway_pods"] = _pods(f"gateway.networking.k8s.io/gateway-name={GATEWAY}")
    s["router_pods"] = _pods("app.kubernetes.io/name=semantic-router")
    r = _kubectl("-n", NS, "get", "agentgatewaybackends", "-o", "json")
    backends = []
    if r.returncode == 0:
        for b in json.loads(r.stdout).get("items", []):
            prov = (b.get("spec", {}).get("ai", {}).get("provider") or {})
            kind = next(iter(prov), "")
            backends.append({"name": b["metadata"]["name"], "provider": kind,
                             "model": (prov.get(kind) or {}).get("model", "")})
    s["backends"] = backends
    r = _kubectl("-n", "model", "get", "pods", "-l", "app=llm", "-o",
                 "jsonpath={range .items[*]}{.metadata.name} {.status.phase} "
                 "{.spec.nodeSelector.cloud\\.google\\.com/compute-class}{'\\n'}{end}")
    s["gemma_pods"] = [ln.split() for ln in r.stdout.splitlines() if ln.strip()] if r.returncode == 0 else []
    return s


def chat(prompt: str, route: str = "auto", max_tokens: int = 300) -> dict:
    spec = ROUTES.get(route, ROUTES["auto"])
    url, via = base_url()
    body = json.dumps({"model": spec["model"], "max_tokens": max_tokens,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    headers = {"Host": LLM_HOST, "Content-Type": "application/json"}
    if spec["header"]:
        headers["x-selected-model"] = spec["header"]
    req = urllib.request.Request(url + "/v1/chat/completions", data=body, headers=headers, method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            code, raw, rh = resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        code, raw, rh = e.code, e.read(), e.headers
    elapsed = round(time.time() - t0, 2)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = {"raw": raw.decode(errors="replace")[:800]}
    model = data.get("model", "") if isinstance(data, dict) else ""
    msg = ""
    if isinstance(data, dict) and data.get("choices"):
        msg = data["choices"][0].get("message", {}).get("content", "") or ""
    usage = data.get("usage", {}) if isinstance(data, dict) else {}
    routing = {k.lower(): v for k, v in rh.items() if k.lower().startswith(("x-vsr-", "x-selected-"))
               or k.lower() == "x-request-id"}
    picked = (routing.get("x-vsr-selected-model") or model or spec["model"]).lower()
    return {
        "status": code, "route": route, "via": via, "elapsed": elapsed,
        "model": model, "content": msg, "usage": usage, "routing": routing,
        "target": "gemini" if picked.startswith("gemini") else "gemma",
        "error": None if code == 200 else (data.get("error") if isinstance(data, dict) else None) or data,
    }


def stop():
    global _pf
    with _pf_lock:
        if _pf is not None:
            _pf.kill()
            _pf = None
