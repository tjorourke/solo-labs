const money = n => (n < 0 ? '-$' : '$') + Math.abs(n).toLocaleString('en-GB', {
  minimumFractionDigits: n >= 100 ? 0 : 2,
  maximumFractionDigits: n >= 100 ? 0 : 2,
});
const compact = n => {
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k';
  return String(Math.round(n));
};

let mcp, mode = 'standard';
const runs = {};
let running = false;

const WRITES = new Set([
  'merge_pull_request', 'update_pull_request', 'create_pull_request',
  'create_or_update_file', 'delete_file', 'push_files', 'create_branch',
  'create_issue', 'update_issue', 'add_issue_comment', 'dismiss_notification',
  'fork_repository', 'create_repository', 'star_repository', 'request_copilot_review',
]);

const YAML = `apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: github-mcp
  namespace: agentgateway-system
spec:
  policies:
    transformation:
      request:
        set:
        - name: X-MCP-Toolsets
          value: '"all"'
  entMcp:
    toolMode: __MODE__
    sessionRouting: Stateful
    failureMode: FailClosed
    targets:
    - name: github
      static:
        host: api.githubcopilot.com
        port: 443
        path: /mcp/
        protocol: StreamableHTTP
        policies:
          tls:
            sni: api.githubcopilot.com
          auth:
            secretRef:
              name: github-mcp-pat`;

function totals(m) {
  const steps = m.steps.filter(s => !s.internal);
  const tin = steps.reduce((a, s) => a + s.tokens_in, 0);
  const tout = steps.reduce((a, s) => a + s.tokens_out, 0);
  const usd = tin * mcp.rates.input_per_m / 1e6 + tout * mcp.rates.output_per_m / 1e6;
  const loops = steps.filter(s => s.kind !== 'tools/list').length;
  return { tin, tout, tokens: tin + tout, usd, loops, tools: m.tools_visible };
}

function setStatus(s) {
  const dot = document.getElementById('dot');
  const label = document.getElementById('status-label');
  if (!dot) return;
  if (s.live && s.live.mcp) {
    dot.className = 'dot live';
    label.textContent = 'live GitHub MCP · mesh1';
  } else if (s.decisions) {
    dot.className = 'dot live';
    label.textContent = s.context ? 'live · ' + s.context.split('/').pop() : 'live';
  } else {
    dot.className = 'dot off';
    label.textContent = s.error || 'cluster not attached';
  }
}

function renderYaml(id) {
  const field = id === 'code' ? 'CodeSearch' : 'Standard';
  const esc = YAML.replace('__MODE__', field)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  document.getElementById('yaml-view').innerHTML =
    esc.replace(/(toolMode:\s*)(\S+)/, '$1<mark>$2</mark>');
}

function renderCloud(names, modeId) {
  const list = [...names].sort();
  document.getElementById('tool-cloud').innerHTML = list.map(t => {
    const cls = modeId === 'code' ? 'keep' : (WRITES.has(t) ? 'write' : '');
    return `<span class="pill ${cls}">${t}</span>`;
  }).join('');
}

function renderReport(r) {
  r = r || mcp.report;
  const groups = r.groups.map(g => {
    const items = g.items.map(it => {
      const num = it.url
        ? `<a class="num" href="${it.url}" target="_blank" rel="noreferrer">#${it.n}</a>`
        : `<span class="num">#${it.n}</span>`;
      return `
      <li>
        ${num}
        <span class="title">${it.title}</span>
        ${it.note ? `<span class="note">${it.note}</span>` : ''}
      </li>`;
    }).join('');
    return `<section class="${g.id}"><h4>${g.label} <b>${g.items.length}</b></h4><ul>${items}</ul></section>`;
  }).join('');
  document.getElementById('answer').innerHTML = `
    <div class="head">
      <h3>${r.title}</h3>
      <a class="repo" href="https://github.com/${r.repo}" target="_blank" rel="noreferrer">${r.repo}</a>
      <span class="count">${r.open} open</span>
    </div>
    <div class="groups">${groups}</div>`;
}

function capture() {
  const usdEl = document.getElementById('m-usd');
  return {
    log: document.getElementById('log').innerHTML,
    answer: document.getElementById('answer').innerHTML,
    answerShow: document.getElementById('answer').classList.contains('show'),
    tools: document.getElementById('m-tools').textContent,
    loops: document.getElementById('m-loops').textContent,
    tokens: document.getElementById('m-tokens').textContent,
    time: document.getElementById('m-time').textContent,
    usd: usdEl.textContent,
    usdClass: usdEl.className,
    cloud: document.getElementById('tool-cloud').innerHTML,
  };
}

function paintReady(m) {
  renderCloud(m.visible_tools || [], m.id);
  document.getElementById('m-tools').textContent = m.tools_visible;
  document.getElementById('m-loops').textContent = '0';
  document.getElementById('m-tokens').textContent = '0';
  document.getElementById('m-time').textContent = '0.0s';
  const usdEl = document.getElementById('m-usd');
  usdEl.textContent = '$0.00';
  usdEl.className = 'value';
  const ans = document.getElementById('answer');
  ans.classList.remove('show');
  ans.innerHTML = '';
  document.getElementById('log').innerHTML =
    `<div class="row in">Ready · ${m.label}. Tools the model can see: ${m.tools_visible}.</div>`;
}

function paintSnap(s) {
  document.getElementById('log').innerHTML = s.log;
  document.getElementById('answer').innerHTML = s.answer;
  document.getElementById('answer').classList.toggle('show', s.answerShow);
  document.getElementById('m-tools').textContent = s.tools;
  document.getElementById('m-loops').textContent = s.loops;
  document.getElementById('m-tokens').textContent = s.tokens;
  document.getElementById('m-time').textContent = s.time;
  const usdEl = document.getElementById('m-usd');
  usdEl.textContent = s.usd;
  usdEl.className = s.usdClass;
  document.getElementById('tool-cloud').innerHTML = s.cloud;
}

function setMode(id) {
  if (running) return;
  mode = id;
  document.getElementById('mode-standard').className = id === 'standard' ? 'on-standard' : '';
  document.getElementById('mode-code').className = id === 'code' ? 'on-codesearch' : '';
  renderYaml(id);
  const m = mcp.modes[id];
  if (runs[id] && runs[id].snap) paintSnap(runs[id].snap);
  else paintReady(m);
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function logLine(html) {
  const log = document.getElementById('log');
  log.insertAdjacentHTML('beforeend', html);
  log.scrollTop = log.scrollHeight;
}

function applyMetrics(ev) {
  document.getElementById('m-loops').textContent = ev.loops;
  document.getElementById('m-tokens').textContent = compact(ev.tokens);
  document.getElementById('m-time').textContent = (ev.ms / 1000).toFixed(1) + 's';
  const usdEl = document.getElementById('m-usd');
  usdEl.textContent = money(ev.usd);
  usdEl.className = 'value ' + (mode === 'code' ? 'good' : 'bad');
}

async function run() {
  if (running) return;
  running = true;
  const btn = document.getElementById('run');
  btn.disabled = true;
  document.getElementById('answer').classList.remove('show');
  document.getElementById('log').innerHTML = '';
  logLine('<div class="row in">Live run through agentgateway on mesh1.</div>');
  const prompt = document.getElementById('mcp-prompt').value.trim();
  let last = { loops: 0, tokens: 0, usd: 0, ms: 0, tools: 0 };
  try {
    const resp = await fetch('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode, prompt }),
    });
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        let ev;
        try { ev = JSON.parse(line); } catch { continue; }
        if (ev.type === 'status') logLine(`<div class="row in">${ev.text}</div>`);
        if (ev.type === 'error') logLine(`<div class="row"><span class="bad">${ev.text}</span></div>`);
        if (ev.type === 'step') logLine(`<div class="row"><span class="k">${ev.title}</span> · ${ev.detail || ''}</div>`);
        if (ev.type === 'tools') {
          document.getElementById('m-tools').textContent = ev.count;
          if (mcp.modes[mode]) {
            mcp.modes[mode].visible_tools = ev.names || [];
            mcp.modes[mode].tools_visible = ev.count;
          }
          renderCloud(ev.names || [], mode);
        }
        if (ev.type === 'metrics' || ev.type === 'done') {
          last = ev;
          applyMetrics(ev);
        }
        if (ev.type === 'report' && ev.report) {
          renderReport(ev.report);
          document.getElementById('answer').classList.add('show');
        }
      }
    }
    runs[mode] = {
      usd: last.usd || 0,
      loops: last.loops || 0,
      tokens: last.tokens || 0,
      live: true,
      snap: capture(),
    };
    showCompare();
  } catch (e) {
    logLine(`<div class="row"><span class="bad">${e}</span></div>`);
  }
  running = false;
  btn.disabled = false;
}

function showCompare() {
  if (!runs.standard || !runs.code) return;
  const a = runs.standard, b = runs.code;
  document.getElementById('cmp-usd').textContent = (a.usd / b.usd).toFixed(0) + 'x';
  document.getElementById('cmp-loops').textContent = a.loops + ' to ' + b.loops;
  document.getElementById('cmp-tokens').textContent = compact(a.tokens) + ' to ' + compact(b.tokens);
  const month = mcp.projection.runs_per_day * mcp.projection.days;
  const save = (a.usd - b.usd) * month;
  document.getElementById('cmp-note').innerHTML =
    `<b>${money(a.usd - b.usd)} kept on every request.</b>` +
    `Standard ${money(a.usd)}, code mode ${money(b.usd)}. ` +
    `At ${mcp.projection.runs_per_day} a day that is ${money(save)} a month.`;
  document.getElementById('compare').classList.add('show');
}

async function boot() {
  const [md, st] = await Promise.all([
    fetch('/api/mcp').then(r => r.json()),
    fetch('/api/status').then(r => r.json()).catch(() => ({})),
  ]);
  mcp = md;
  setStatus(st);
  const box = document.getElementById('mcp-prompt');
  if (!box.value.trim()) box.value = mcp.prompt;
  document.getElementById('mode-standard').onclick = () => setMode('standard');
  document.getElementById('mode-code').onclick = () => setMode('code');
  document.getElementById('run').onclick = run;
  setMode('standard');
  try {
    const live = await fetch('/api/mcp/tools?mode=standard').then(r => r.json());
    if (live.names && live.names.length) {
      mcp.modes.standard.visible_tools = live.names;
      mcp.modes.standard.tools_visible = live.count || live.names.length;
      if (mode === 'standard' && !(runs.standard && runs.standard.snap)) {
        paintReady(mcp.modes.standard);
      }
    }
  } catch (e) { /* snapshot already painted */ }
}

boot();
