// Token economics, second tab: the quadratic on a calculator MCP server.
// Same model, same question, Standard vs Code mode, measured live.
(() => {
  const $ = id => document.getElementById(id);
  const RATES = { in: 3.0, out: 15.0 };
  const money = n => '$' + n.toFixed(n >= 1 ? 2 : 4);
  const compact = n => n >= 1e3 ? (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k' : String(Math.round(n));
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const TOOLS = { standard: ['add', 'sub', 'mul', 'div', 'sqrt', 'pow'], code: ['run_code'] };
  const YAML = `apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: calc-mcp
  namespace: agentgateway-system
spec:
  entMcp:
    toolMode: __MODE__
    sessionRouting: Stateful
    targets:
    - name: calc
      static:
        host: calc-mcp.agentgateway-system.svc.cluster.local
        port: 3000
        path: /mcp
        protocol: StreamableHTTP`;

  let mode = 'standard', running = false;
  const runs = {};

  // tabs
  document.querySelectorAll('[data-econ-tab]').forEach(tab => {
    tab.onclick = () => {
      document.querySelectorAll('[data-econ-tab]').forEach(t => t.setAttribute('aria-selected', String(t === tab)));
      document.querySelectorAll('[data-econ-pane]').forEach(p => { p.hidden = p.dataset.econPane !== tab.dataset.econTab; });
      history.replaceState(null, '', tab.dataset.econTab === 'github' ? location.pathname : '#' + tab.dataset.econTab);
    };
  });
  if (location.hash === '#quadratic') document.querySelector('[data-econ-tab="quadratic"]').click();

  function cloud(names) {
    $('q-tool-cloud').innerHTML = names.map(n => `<span class="pill ${mode === 'code' ? 'keep' : ''}">${esc(n)}</span>`).join('');
  }

  function ready() {
    cloud(TOOLS[mode]);
    $('q-m-tools').textContent = TOOLS[mode].length;
    ['q-m-loops', 'q-m-tokens'].forEach(id => { $(id).textContent = '0'; });
    $('q-m-time').textContent = '0.0s';
    $('q-m-usd').textContent = '$0.00';
    $('q-m-usd').className = 'value';
    $('q-answer').classList.remove('show');
    $('q-log').innerHTML = `<div class="row in">Ready · ${mode === 'code' ? 'Code mode' : 'Standard MCP'}. Tools the model can see: ${TOOLS[mode].length}.</div>`;
  }

  function snapshot() {
    return ['q-log', 'q-answer', 'q-tool-cloud', 'q-m-tools', 'q-m-loops', 'q-m-tokens', 'q-m-time', 'q-m-usd']
      .reduce((o, id) => ({ ...o, [id]: [$(id).innerHTML, $(id).className] }), {});
  }

  function restore(s) {
    Object.entries(s).forEach(([id, [html, cls]]) => { $(id).innerHTML = html; $(id).className = cls; });
  }

  function setMode(m) {
    if (running) return;
    mode = m;
    $('q-mode-standard').className = m === 'standard' ? 'on-standard' : '';
    $('q-mode-code').className = m === 'code' ? 'on-codesearch' : '';
    $('q-yaml-view').innerHTML = esc(YAML.replace('__MODE__', m === 'code' ? 'Code' : 'Standard'))
      .replace(/(toolMode:\s*)(\S+)/, '$1<mark>$2</mark>');
    if (runs[m]) restore(runs[m].snap); else ready();
  }

  function line(html) {
    $('q-log').insertAdjacentHTML('beforeend', html);
    $('q-log').scrollTop = $('q-log').scrollHeight;
  }

  function metrics(ev) {
    $('q-m-loops').textContent = ev.loops;
    $('q-m-tokens').textContent = compact(ev.tokens);
    $('q-m-time').textContent = (ev.ms / 1000).toFixed(1) + 's';
    $('q-m-usd').textContent = money(ev.usd);
    $('q-m-usd').className = 'value ' + (mode === 'code' ? 'good' : 'bad');
  }

  function compare() {
    if (!runs.standard || !runs.code) return;
    const a = runs.standard, b = runs.code;
    $('q-cmp-usd').textContent = (a.usd / b.usd).toFixed(1).replace(/\.0$/, '') + 'x';
    $('q-cmp-loops').textContent = a.loops + ' to ' + b.loops;
    $('q-cmp-tokens').textContent = compact(a.tokens) + ' to ' + compact(b.tokens);
    $('q-cmp-note').innerHTML = `<b>Same roots, ${money(a.usd - b.usd)} less per question.</b> ` +
      `Standard ${money(a.usd)} over ${a.loops} tool calls, Code mode ${money(b.usd)} over ${b.loops}.`;
    $('q-compare').classList.add('show');
  }

  async function run() {
    if (running) return;
    running = true;
    $('q-run').disabled = true;
    $('q-answer').classList.remove('show');
    $('q-log').innerHTML = '<div class="row in">Live run through agentgateway on mesh1.</div>';
    let last = null;
    try {
      const resp = await fetch('/api/quadratic/run', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode }),
      });
      const reader = resp.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const l of lines) {
          if (!l.trim()) continue;
          let ev;
          try { ev = JSON.parse(l); } catch { continue; }
          if (ev.type === 'status') line(`<div class="row in">${esc(ev.text)}</div>`);
          if (ev.type === 'error') line(`<div class="row"><span class="bad">${esc(ev.text)}</span></div>`);
          if (ev.type === 'tools') { cloud(ev.names); $('q-m-tools').textContent = ev.count; }
          if (ev.type === 'step') {
            const body = ev.title === 'run_code'
              ? `<div class="q-code">${esc(ev.detail.trim())}</div>`
              : ` · ${esc(ev.detail)}`;
            line(`<div class="row"><span class="k">${esc(ev.title)}</span>${body} → ${esc(ev.result || '')}</div>`);
          }
          if (ev.type === 'metrics' || ev.type === 'done') { last = ev; metrics(ev); }
          if (ev.type === 'answer') {
            $('q-answer').innerHTML = `<div class="head"><h3>Answer</h3><span class="count">${esc(ev.model || 'Claude')}</span></div>` +
              `<p class="roots">${esc(ev.text || '(no answer)')}</p>`;
            $('q-answer').classList.add('show');
          }
        }
      }
      if (last && last.type === 'done') {
        runs[mode] = { usd: last.usd, loops: last.loops, tokens: last.tokens, snap: snapshot() };
        compare();
      }
    } catch (e) {
      line(`<div class="row"><span class="bad">${esc(e)}</span></div>`);
    }
    running = false;
    $('q-run').disabled = false;
  }

  $('q-mode-standard').onclick = () => setMode('standard');
  $('q-mode-code').onclick = () => setMode('code');
  $('q-run').onclick = run;
  setMode('standard');
})();
