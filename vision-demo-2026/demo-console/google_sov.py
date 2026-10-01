"""Google Sovereign Cloud: the Berlin GCD agentgateway, from the console.

Two routes behind one gateway, chosen by vLLM Semantic Router (VSR) as an
extProc at PreRouting:

    gemma   Gemma 3 27B on an H100 inside the cluster. Never leaves Berlin.
    gemini  Gemini 2.5 Flash, Google's frontier model, out through Cloud NAT.

The gateway is internal to the GCD VPC. Set GCD_AGW_URL when something already
reaches it (an external LB, a tunnel); otherwise this module opens its own
kubectl port-forward to the gateway Service, using the Berlin kubeconfig.

    GCD_AGW_URL       e.g. http://34.x.x.x  (unset: port-forward)
    GCD_LLM_HOST      Host header the HTTPRoute matches (models.agentic.eu0.internal)
    GCD_KUBECONFIG    ~/code/google-sov/poc/2026-09-agentic-platform/deploy/.kubeconfig
    GCD_UNIVERSE      apis-berlin-build0.goog
    GCD_AGW_NS        agentgateway-system
    GCD_AGW_GATEWAY   agentgateway-models
    GCD_PF_PORT       18090
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

LLM_HOST = os.environ.get("GCD_LLM_HOST", "models.agentic.eu0.internal")
KUBECONFIG = os.path.expanduser(os.environ.get(
    "GCD_KUBECONFIG", "~/code/google-sov/poc/2026-09-agentic-platform/deploy/.kubeconfig"))
UNIVERSE = os.environ.get("GCD_UNIVERSE", "apis-berlin-build0.goog")
NS = os.environ.get("GCD_AGW_NS", "agentgateway-system")
GATEWAY = os.environ.get("GCD_AGW_GATEWAY", "agentgateway-models")
PF_PORT = int(os.environ.get("GCD_PF_PORT", "18090"))

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
                 "-o", "jsonpath={.items[0].metadata.name}")
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError(_auth_hint(r.stderr) or f"no Service for Gateway {NS}/{GATEWAY} yet")
    return r.stdout.strip()


def _auth_hint(stderr: str) -> str:
    s = stderr or ""
    if "Refresh token has expired" in s or "reauth" in s.lower() or "credential" in s.lower():
        return "Berlin credentials expired: run ./scripts/gcd-auth.sh in ~/code/google-sov"
    return s.strip().splitlines()[-1][:200] if s.strip() else ""


def _reachable(url: str) -> bool:
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers={"Host": LLM_HOST}), timeout=2)
        return True
    except urllib.error.HTTPError:
        return True          # any HTTP answer means the gateway is there
    except Exception:
        return False


def base_url() -> tuple[str, str]:
    """(url, how) — how is 'configured' or 'port-forward'."""
    if os.environ.get("GCD_AGW_URL"):
        return os.environ["GCD_AGW_URL"].rstrip("/"), "configured"
    global _pf
    url = f"http://127.0.0.1:{PF_PORT}"
    with _pf_lock:
        if _pf is not None and _pf.poll() is None and _reachable(url):
            return url, "port-forward"
        if _pf is not None:
            _pf.kill()
            _pf = None
        svc = _gateway_service()
        _pf = subprocess.Popen(["kubectl", "-n", NS, "port-forward", f"svc/{svc}", f"{PF_PORT}:80"],
                               env=_env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        for _ in range(40):
            if _pf.poll() is not None:
                err = _pf.stderr.read() if _pf.stderr else ""
                _pf = None
                raise RuntimeError(_auth_hint(err) or "port-forward exited")
            if _reachable(url):
                return url, "port-forward"
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
