#!/usr/bin/env python3
"""Live decision dashboard for the task-routing lab.

    KUBE_CONTEXT=<lab-context> python3 scripts/30-dashboard.py
    Then open http://localhost:8900

One card per request: who asked, the task the router chose, what OPA decided and why,
which model answered and with what status. Join two logs by trace ID AND span ID:

    opa                decision log       task label, subject, prompt, pool and class
    decision-gateway   access log         the backend that answered, the model, the status

Nothing is written to the cluster. Close it with ctrl-c.
"""
import html
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = os.environ.get("DASHBOARD_NAMESPACE", "agentgateway-system")
PORT = int(os.environ.get("DASHBOARD_PORT", "8900"))
SINCE = os.environ.get("DASHBOARD_SINCE", "15m")
# Pin the cluster. This reads logs with kubectl, and kubectl follows whatever context is
# current, so a context switch in another terminal silently pointed the dashboard at a
# different cluster and it sat there showing nothing. Override with KUBE_CONTEXT.
CTX = os.environ.get("KUBE_CONTEXT", "")

cards = []            # newest last
subscribers = []      # queues, one per browser
lock = threading.Lock()
followers = set()


# --- helpers ---------------------------------------------------------------------------

def publish(card):
    payload = json.dumps(card)
    with lock:
        for q in list(subscribers):
            q.put(payload)


def new_card(**kw):
    card = {"id": uuid.uuid4().hex[:12], "ts": time.time(), "open": True}
    card.update(kw)
    with lock:
        cards.append(card)
        del cards[:-200]
    publish(card)
    return card


def request_key(trace_id, span_id):
    if (re.fullmatch(r"[0-9a-f]{32}", trace_id or "")
            and re.fullmatch(r"[0-9a-f]{16}", span_id or "")
            and int(trace_id, 16) and int(span_id, 16)):
        return trace_id + ":" + span_id
    return None


def event_time(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return time.time()


def upsert_event(key, **fields):
    # OPA sees the decision-gateway traceparent; the access log contains the same
    # trace.id and span.id. Never guess by user, timing, prompt or completion order.
    with lock:
        card = next((c for c in cards if key and c.get("request_key") == key), None)
        if card is None:
            card = {"id": key or uuid.uuid4().hex, "ts": time.time(),
                    "request_key": key, "correlation": "exact" if key else "unmatched"}
            cards.append(card)
        card.update(fields)
        if "decision_ts" in card:
            card["ts"] = card["decision_ts"]
        elif "completed_ts" in card:
            card["ts"] = card["completed_ts"]
        del cards[:-200]
        snapshot = dict(card)
    publish(snapshot)
    return card


def follow(target, handler):
    """Follow one deployment's log, restarting if the pod goes away."""
    while True:
        p = subprocess.Popen(
            ["kubectl", "--context", CTX, "-n", NS, "logs", "-f", f"--since={SINCE}", f"deploy/{target}"],
            stdout=subprocess.PIPE, text=True, bufsize=1)
        with lock:
            followers.add(p)
        try:
            for line in p.stdout:
                try:
                    handler(line.rstrip("\n"))
                except Exception as error:
                    print(f"Could not process a {target} event: {type(error).__name__}", flush=True)
        finally:
            if p.poll() is None:
                p.terminate()
            with lock:
                followers.discard(p)
        time.sleep(2)


def _text(content):
    """Message content is a string in a plain chat and a list of parts in an agent one."""
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content if isinstance(content, str) else ""


# Claude Code and Claude Desktop wrap every turn in machinery the person never typed:
# <system-reminder> blocks carrying CLAUDE.md, the memory index and the git status, and a
# <session> envelope on the request that names the conversation. Showing that verbatim puts
# a repository's instructions and someone's file tree on screen, which is the last thing you
# want in front of a customer, and it buries the actual question.
_ENVELOPE = re.compile(
    r"<system-reminder>.*?</system-reminder>"
    r"|<system_reminder>.*?</system_reminder>",
    re.S,
)

# The client's own background calls. Neither is anything the person asked for: the first
# names the conversation in the sidebar, the second recaps it after a pause. They are worth
# labelling rather than hiding, because they still cost tokens and still get routed.
_HOUSEKEEPING = (
    "succinct title for an agent chat session",
    "Write the title in the predominant language",
    "You are naming a coding session",
    "The user stepped away and is coming back",
)


def strip_envelope(text):
    """What the person actually typed, with the client's machinery taken out."""
    out = _ENVELOPE.sub(" ", text or "")
    out = re.sub(r"</?(session|pasted_content)[^>]*>", " ", out)
    return re.sub(r"[ \t]*\n[ \t]*\n+", "\n\n", out).strip()


def read_prompt(body_text):
    """The last user message, the question inside it, and a key that groups one conversation.

    An editor sends the same question on every turn of a task, wrapped in <user_query> tags
    somewhere in the conversation, so that question is what ties a loop together.
    """
    try:
        body = json.loads(body_text)
    except Exception:
        return "", "", "", False
    msgs = body.get("messages", [])
    user = [_text(m.get("content")) for m in msgs if m.get("role") == "user"]
    last = user[-1] if user else ""
    joined = "\n".join(_text(m.get("content")) for m in msgs)
    housekeeping = any(marker in joined for marker in _HOUSEKEEPING)
    question = ""
    if "<user_query>" in joined:
        question = joined.split("<user_query>")[-1].split("</user_query>")[0].strip()
    if not question:
        question = strip_envelope(last)
    if housekeeping:
        # Say what it is rather than printing the instructions the client sent itself.
        # These carry the session content, so the text is a duplicate of a row already on
        # screen, and the meta-prompt is the noise that makes a real answer look misrouted.
        which = ("naming the session" if "title" in joined.lower() else "recapping the session")
        question = f"(client housekeeping: {which})"
    return last, question, (question[:400] or "no prompt"), housekeeping


# --- the three log readers -------------------------------------------------------------

# This router build emits an empty request_id in routing_decision logs. Its timing
# cannot be correlated safely, so do not display a guessed classification latency.
# OPA's input has the authoritative x-selected-model for the individual request.


def on_opa(line):
    if '"decision_id"' not in line:
        return
    try:
        d = json.loads(line)
    except Exception:
        return
    attrs = d.get("input", {}).get("attributes", {})
    http_in = attrs.get("request", {}).get("http", {})
    if http_in.get("method") != "POST":
        return
    sub = (attrs.get("metadataContext", {}).get("filterMetadata", {})
           .get("envoy.filters.http.jwt_authn", {}).get("jwt_payload", {}).get("sub"))
    result = d.get("result") or {}
    headers = result.get("headers", {}) if result.get("allowed") else {}
    request_headers = http_in.get("headers", {})
    task = request_headers.get("x-selected-model")
    parent = request_headers.get("traceparent", "").split("-")
    key = request_key(parent[1], parent[2]) if len(parent) == 4 else None
    prompt, question, thread, housekeeping = read_prompt(http_in.get("body", ""))
    upsert_event(
        key,
        decision_ts=event_time(d.get("timestamp")),
        decision_id=d.get("decision_id"),
        user=sub,
        # The envelope is stripped for display. The raw body is what the gateway routed on
        # and is still in the gateway's own logs; it is not something to put on a screen.
        prompt=question,
        housekeeping=housekeeping,
        question=question,
        thread=thread,
        task=task,
        allowed=bool(result.get("allowed")),
        pool=headers.get("x-model-pool"),
        mclass=headers.get("x-model-class"),
        reason=headers.get("x-routing-reason") or (result.get("headers", {}) or {}).get("x-routing-reason"),
        refused_status=None if result.get("allowed") else result.get("http_status"),
        refused_body=None if result.get("allowed") else str(result.get("body", ""))[:300],
        source_repo=http_in.get("headers", {}).get("x-source-repo"),
    )


ACCESS = re.compile(r'(\w[\w.]*)=([^\s]+)')

def on_gateway(line):
    if "http.path=/v1/chat/completions" not in line:
        return
    f = dict(ACCESS.findall(line))
    sub = f.get("jwt.sub")
    key = request_key(f.get("trace.id"), f.get("span.id"))
    patch = {
        "status": f.get("http.status"),
        "answered_by": f.get("gen_ai.response.model") or f.get("gen_ai.request.model"),
        "endpoint": f.get("endpoint"),
        "duration": f.get("duration"),
        "open": False,
        "completed_ts": event_time(line.split()[0]),
        "trace_id": f.get("trace.id"),
        "span_id": f.get("span.id"),
    }
    if sub:
        patch["user"] = sub
    upsert_event(key, **patch)


# --- the page --------------------------------------------------------------------------

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Gateway decisions</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'%3E%3Cg stroke='%23a78bfa' stroke-width='2.4' opacity='0.6' stroke-linecap='round'%3E%3Cline x1='24' y1='7' x2='7' y2='24'/%3E%3Cline x1='24' y1='7' x2='41' y2='24'/%3E%3Cline x1='7' y1='24' x2='41' y2='24'/%3E%3Cline x1='7' y1='24' x2='24' y2='41'/%3E%3Cline x1='41' y1='24' x2='24' y2='41'/%3E%3C/g%3E%3Ccircle cx='24' cy='7' r='5' fill='%23a78bfa'/%3E%3Ccircle cx='7' cy='24' r='5' fill='%237c3aed'/%3E%3Ccircle cx='41' cy='24' r='5' fill='%237c3aed'/%3E%3Ccircle cx='24' cy='41' r='5' fill='%235b21b6'/%3E%3C/svg%3E">
<style>
 :root { color-scheme: light; }
 * { box-sizing: border-box; }
 body { margin:0; font:15px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif; background:#f1f5f9; color:#0f172a; }
 header { position:sticky; top:0; z-index:5; background:#fff; border-bottom:1px solid #d8e0ea; padding:12px 22px 10px; }
 .bar { display:flex; gap:14px; align-items:baseline; flex-wrap:wrap; }
 header h1 { margin:0; font-size:17px; }
 header { border-bottom:1px solid #d8e0ea; box-shadow:inset 0 3px 0 #7c3aed; }
 .brand { display:flex; align-items:center; gap:9px; }
 .brand svg { display:block; flex:none; }
 header .tag { color:#64748b; font-size:13px; }
 #count { margin-left:auto; color:#64748b; font-size:13px; font-variant-numeric:tabular-nums; }
 .filters { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-top:10px; }
 .filters select, .filters input {
   font:13px ui-sans-serif,system-ui,sans-serif; color:#0f172a; background:#f8fafc;
   border:1px solid #cbd5e1; border-radius:7px; padding:5px 9px; min-width:120px;
 }
 .filters input { min-width:180px; }
 .filters input[type="checkbox"] { min-width:0; width:auto; padding:0; }
 .filters select:focus, .filters input:focus { outline:2px solid rgba(14,116,144,.35); outline-offset:1px; }
 .btn {
   font:13px ui-sans-serif,system-ui,sans-serif; border-radius:7px; padding:5px 12px; cursor:pointer;
   border:1px solid #cbd5e1; background:#fff; color:#334155;
 }
 .btn:hover { border-color:#94a3b8; }
 .btn.clear { border-color:#fca5a5; color:#b91c1c; background:#fef2f2; }
 .btn.clear:hover { border-color:#ef4444; }
 .btn.live { border-color:#86efac; color:#15803d; background:#f0fdf4; }
 .btn.paused { border-color:#fcd34d; color:#b45309; background:#fffbeb; }
 #list { padding:18px 22px 60px; max-width:1100px; }
 .card { background:#fff; border:1px solid #d8e0ea; border-left-width:5px; border-radius:10px; padding:14px 16px; margin:0 0 12px; box-shadow:0 1px 2px rgba(15,23,42,.04); }
 .card.private { border-left-color:#16a34a; }
 .card.frontier { border-left-color:#d97706; }
 .card.refused  { border-left-color:#dc2626; }
 .card.pending  { border-left-color:#94a3b8; }
 .top { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:8px; }
 .when { margin-left:auto; color:#64748b; font:12.5px ui-monospace,Menlo,monospace; white-space:nowrap; }
 .who { font-weight:700; }
 .pill { font:12px ui-monospace,Menlo,monospace; padding:2px 8px; border-radius:999px; border:1px solid #cbd5e1; background:#f8fafc; color:#334155; }
 .pill.task { border-color:#0e7490; color:#0e7490; background:rgba(14,116,144,.07); }
 .pill.pool-private { border-color:#16a34a; color:#15803d; background:rgba(22,163,74,.08); }
 .pill.pool-approved-frontier { border-color:#d97706; color:#b45309; background:rgba(217,119,6,.09); }
 .pill.bad { border-color:#dc2626; color:#b91c1c; background:rgba(220,38,38,.08); }
 .prompt { background:#f8fafc; border:1px solid #e2e8f0; border-radius:8px; padding:9px 11px; font:13.5px ui-monospace,Menlo,monospace; color:#334155; white-space:pre-wrap; word-break:break-word; max-height:120px; overflow:auto; }
 .meta { margin-top:8px; color:#64748b; font-size:13px; display:flex; gap:16px; flex-wrap:wrap; }
 .meta b { color:#0f172a; font-weight:600; }
 .count { color:#64748b; font-size:13px; }
 details { margin-top:10px; }
 summary { cursor:pointer; color:#0e7490; font-size:13px; padding:2px 0; list-style:none; }
 summary::-webkit-details-marker { display:none; }
 summary::before { content:'▸ '; }
 details[open] summary::before { content:'▾ '; }
 .turn { display:flex; gap:8px; align-items:center; flex-wrap:wrap; padding:7px 10px; margin:6px 0 0;
         border:1px solid #e2e8f0; border-left-width:3px; border-radius:7px; background:#fbfcfe; }
 .turn.private { border-left-color:#16a34a; }
 .turn.frontier { border-left-color:#d97706; }
 .turn.refused { border-left-color:#dc2626; }
 .turn.pending { border-left-color:#94a3b8; }
 .tw { font:12px ui-monospace,Menlo,monospace; color:#64748b; }
 .tmeta { color:#64748b; font-size:12.5px; }
 .tmeta b { color:#0f172a; font-weight:600; }
 .empty { color:#64748b; padding:40px 0; }
</style></head><body>
<header>
  <div class="bar">
    <span class="brand"><svg width="24" height="24" viewBox="0 0 48 48" aria-hidden="true">
      <g stroke="#a78bfa" stroke-width="2.4" opacity="0.6" stroke-linecap="round">
        <line x1="24" y1="7" x2="7" y2="24"/><line x1="24" y1="7" x2="41" y2="24"/>
        <line x1="7" y1="24" x2="41" y2="24"/><line x1="7" y1="24" x2="24" y2="41"/>
        <line x1="41" y1="24" x2="24" y2="41"/>
      </g>
      <circle cx="24" cy="7" r="5" fill="#a78bfa"/><circle cx="7" cy="24" r="5" fill="#7c3aed"/>
      <circle cx="41" cy="24" r="5" fill="#7c3aed"/><circle cx="24" cy="41" r="5" fill="#5b21b6"/>
    </svg><h1>Gateway decisions</h1></span><span class="tag">VSR classification, OPA policy and backend result · matched by trace ID</span>
    <span id="count"></span>
  </div>
  <div class="filters">
    <select id="f-user"><option value="">Everyone</option></select>
    <select id="f-task"><option value="">Any task</option></select>
    <select id="f-pool"><option value="">Any pool</option></select>
    <select id="f-model"><option value="">Any model</option></select>
    <select id="f-status"><option value="">Any status</option></select>
    <label style="display:flex;gap:5px;align-items:center;font-size:13px;color:#475569;white-space:nowrap">
      <input id="f-house" type="checkbox"> hide housekeeping</label>
    <input id="f-text" type="search" placeholder="Search the prompt">
    <button class="btn" id="reset">Reset filters</button>
    <button class="btn live" id="pause">Live</button>
    <button class="btn clear" id="clear">Clear</button>
  </div>
</header>
<div id="list"><div class="empty">Waiting for a request.</div></div>
<script>
const list = document.getElementById('list');
const F = {user:'f-user', task:'f-task', pool:'f-pool', model:'f-model', status:'f-status'};
let cards = [], paused = false, buffer = [];

function when(ts) {
  const d = new Date(ts * 1000), p = n => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth()+1)} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
function esc(s) { return String(s).replace(/[<>&]/g, m => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[m])); }
function pill(text, cls) { return text ? `<span class="pill ${cls||''}">${esc(text)}</span>` : ''; }
function kind(c) {
  if (c.allowed === false) return 'refused';
  if (c.status && c.status !== '200') return 'refused';
  if (!c.status) return 'pending';
  if (c.pool === 'private') return 'private';
  if (c.pool === 'approved-frontier') return 'frontier';
  return 'pending';
}
function value(c, key) {
  return key === 'model' ? (c.answered_by || '') : (c[key === 'user' ? 'user' : key] || '');
}
function options() {
  for (const [key, id] of Object.entries(F)) {
    const sel = document.getElementById(id), have = new Set([...sel.options].map(o => o.value));
    const seen = [...new Set(cards.map(c => value(c, key)).filter(Boolean))].sort();
    for (const v of seen) if (!have.has(v)) sel.add(new Option(v, v));
  }
}
function matches(c) {
  for (const [key, id] of Object.entries(F)) {
    const want = document.getElementById(id).value;
    if (want && value(c, key) !== want) return false;
  }
  const q = document.getElementById('f-text').value.trim().toLowerCase();
  if (q && !(c.prompt || '').toLowerCase().includes(q)) return false;
  if (document.getElementById('f-house').checked && c.housekeeping) return false;
  return true;
}
function turn(c) {
  return `<div class="turn ${kind(c)}">
    <span class="tw">${when(c.ts).split(' ')[1]}</span>
    ${pill(c.task, 'task')}
    ${pill(c.pool, 'pool-' + (c.pool || ''))}
    ${pill(c.mclass)}
    ${c.status ? pill('HTTP ' + c.status, c.status === '200' ? '' : 'bad') : pill('Awaiting response')}
    ${c.answered_by ? pill(c.answered_by) : ''}
    ${c.correlation === 'unmatched' ? pill('No request ID: not correlated') : ''}
    ${c.trace_id ? pill('trace ' + c.trace_id.slice(0, 12)) : ''}
    <span class="tmeta">${c.reason ? `reason <b>${esc(c.reason)}</b>` : ''}${c.latency_ms ? ` · classified in <b>${c.latency_ms} ms</b>` : ''}${c.duration ? ` · took <b>${esc(c.duration)}</b>` : ''}${c.refused_body ? ` · <b>${esc(c.refused_body)}</b>` : ''}</span>
  </div>`;
}
const opened = new Set();
function group(g) {
  g.cards.sort((a, b) => a.ts - b.ts);
  const first = g.cards[0], latest = g.cards[g.cards.length - 1];
  const pools = [...new Set(g.cards.map(c => c.pool).filter(Boolean))];
  const models = [...new Set(g.cards.map(c => c.answered_by).filter(Boolean))];
  const bad = g.cards.some(c => c.allowed === false || (c.status && c.status !== '200'));
  const cls = bad ? 'refused' : (g.cards.some(c => !c.status) ? 'pending' : (pools.includes('approved-frontier') ? 'frontier'
            : (pools.includes('private') ? 'private' : 'pending')));
  const n = g.cards.length;
  return `<div class="card ${cls}">
    <div class="top">
      <span class="who">${esc(first.user || 'unknown')}</span>
      ${pools.map(p => pill(p, 'pool-' + p)).join('')}
      ${models.map(m => pill(m)).join('')}
      ${first.source_repo ? pill('repo ' + first.source_repo) : ''}
      <span class="when">${when(first.ts)}${n > 1 ? ' to ' + when(latest.ts).split(' ')[1] : ''}</span>
    </div>
    <div class="prompt">${esc(first.question || first.prompt || '(response received; awaiting its policy event)')}</div>
    <details data-key="${encodeURIComponent(g.key)}"${(n === 1 || opened.has(g.key)) ? ' open' : ''}>
      <summary>${n > 1 ? `${n} requests with the same displayed prompt` : '1 request'}</summary>
      ${g.cards.map(turn).join('')}
    </details>
  </div>`;
}
function rememberToggles() {
  for (const d of document.querySelectorAll('details[data-key]')) {
    const key = decodeURIComponent(d.dataset.key);
    if (d.dataset.bound) continue;
    d.dataset.bound = '1';
    d.addEventListener('toggle', () => d.open ? opened.add(key) : opened.delete(key));
  }
}
function render() {
  options();
  const shown = cards.filter(matches);
  const groups = new Map();
  for (const c of shown) {
    const key = JSON.stringify([c.user || '', c.housekeeping ? c.id : (c.thread || c.prompt || c.id)]);
    if (!groups.has(key)) groups.set(key, {key, cards: []});
    groups.get(key).cards.push(c);
  }
  const ordered = [...groups.values()].sort(
    (a, b) => Math.max(...b.cards.map(c => c.ts)) - Math.max(...a.cards.map(c => c.ts)));
  list.innerHTML = ordered.length ? ordered.map(group).join('')
                                  : '<div class="empty">Nothing matches those filters.</div>';
  rememberToggles();
  const n = cards.length, g = ordered.length;
  const scope = shown.length === n ? `${n}` : `${shown.length} of ${n}`;
  document.getElementById('count').textContent =
    `${scope} request${n === 1 ? '' : 's'} in ${g} prompt group${g === 1 ? '' : 's'}`;
}
function upsert(c) {
  const i = cards.findIndex(x => x.id === c.id);
  if (i >= 0) cards[i] = c; else cards.push(c);
}
new EventSource('/events').onmessage = e => {
  const c = JSON.parse(e.data);
  if (paused) { buffer.push(c); document.getElementById('pause').textContent = `Paused (${buffer.length})`; return; }
  upsert(c); render();
};
for (const id of [...Object.values(F), 'f-text', 'f-house']) {
  document.getElementById(id).addEventListener('input', render);
}
document.getElementById('f-house').addEventListener('change', render);
document.getElementById('reset').onclick = () => {
  for (const id of Object.values(F)) document.getElementById(id).value = '';
  document.getElementById('f-text').value = '';
  document.getElementById('f-house').checked = false;
  render();
};
document.getElementById('pause').onclick = e => {
  paused = !paused;
  if (!paused) { buffer.forEach(upsert); buffer = []; render(); }
  e.target.textContent = paused ? 'Paused (0)' : 'Live';
  e.target.className = 'btn ' + (paused ? 'paused' : 'live');
};
document.getElementById('clear').onclick = async () => {
  await fetch('/clear', {method: 'POST'});
  cards = []; buffer = [];
  for (const id of Object.values(F)) {
    const sel = document.getElementById(id);
    sel.length = 1; sel.value = '';
  }
  render();
};
render();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        # The Clear button empties the server's backlog too, so a reload stays clean.
        if self.path == "/clear":
            with lock:
                cards.clear()
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            q = queue.Queue()
            with lock:
                subscribers.append(q)
                backlog = list(cards[-40:])
            try:
                for card in backlog:
                    self.wfile.write(f"data: {json.dumps(card)}\n\n".encode())
                self.wfile.flush()
                while True:
                    try:
                        payload = q.get(timeout=15)
                        self.wfile.write(f"data: {payload}\n\n".encode())
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                with lock:
                    if q in subscribers:
                        subscribers.remove(q)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(PAGE.encode())


def main():
    if not CTX:
        raise SystemExit("Set KUBE_CONTEXT to the task-routing cluster before starting the dashboard.")
    # Fail before opening an empty UI if the wrong context or namespace was supplied.
    subprocess.run(["kubectl", "--context", CTX, "-n", NS, "get", "deployment",
                    "opa", "decision-gateway", "-o", "name"], check=True)
    for target, handler in (("opa", on_opa),
                            ("decision-gateway", on_gateway)):
        threading.Thread(target=follow, args=(target, handler), daemon=True).start()
    print(f"dashboard on http://localhost:{PORT}  (ctrl-c to stop)")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    finally:
        with lock:
            children = list(followers)
        for child in children:
            if child.poll() is None:
                child.terminate()


if __name__ == "__main__":
    main()
