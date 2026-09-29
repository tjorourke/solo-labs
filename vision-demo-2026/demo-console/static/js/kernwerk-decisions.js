const el = id => document.getElementById(id);
const open = new Set();
let last = '';

function result(d) {
  const st = state(d);
  if (st === 'stopped') return '<span class="pill frontier">Stopped at the gateway</span>';
  if (st === 'failed') return `<span class="pill frontier">No answer (${esc(d.status)})</span>`;
  if (st === 'waiting') return '<span class="pill">Waiting for the model</span>';
  return '<span class="pill private">Answered</span>';
}

function row(d) {
  const L = LANES[d.lane];
  const found = d.masked ? removals(d.prompt, d.masked) : [];
  const back = d.answer_original && d.answer ? removals(d.answer_original, d.answer) : [];
  const text = splitFiles(esc(d.prompt), d.files);
  const snippet = text.body.replace(/\s+/g, ' ').trim();
  const replaced = found.length || back.length
    ? chips(found) + (back.length ? ` <span class="kw-back">${found.length ? 'and in' : 'In'} the answer</span> ${chips(back)}` : '')
    : '<span class="kw-none">None</span>';
  const cls = state(d) === 'stopped'
    ? '<span class="kw-none">Stopped first</span>'
    : L ? `<span class="pill ${L.pill}">${L.cls} · ${L.name}</span>` : '<span class="pill">Deciding…</span>';
  const where = state(d) === 'stopped' ? 'Nowhere' : L ? esc(L.short) : '';
  const isOpen = open.has(d.id);
  let html = `<tr class="kw-row${isOpen ? ' open' : ''}" data-id="${esc(d.id)}">
    <td class="num">${stamp(d.ts)}</td><td>${cls}</td><td>${where}</td>
    <td class="prompt">${text.pills}${esc(snippet.length > 140 ? snippet.slice(0, 140) + '…' : snippet)}</td>
    <td>${replaced}</td><td>${result(d)}</td></tr>`;
  if (isOpen) {
    const r = renderDecision(d);
    html += `<tr class="kw-detail"><td colspan="6"><div class="dlp-flow">${r.flow}</div>${r.verdict}
      <a class="kw-open" href="/kernwerk/dlp?id=${encodeURIComponent(d.id)}">Open on the Data protection page →</a></td></tr>`;
  }
  return html;
}

function kpis(list) {
  const n = lane => list.filter(d => d.lane === lane && state(d) !== 'stopped').length;
  const stopped = list.filter(d => state(d) === 'stopped').length;
  const items = list.reduce((t, d) => t + (d.masked ? removals(d.prompt, d.masked).length : 0)
    + (d.answer_original && d.answer ? removals(d.answer_original, d.answer).length : 0), 0);
  const kpi = (cls, labelText, value, hint) =>
    `<div class="kpi ${cls}"><div class="label">${labelText}</div><div class="value">${value}</div><div class="hint">${hint}</div></div>`;
  el('kpis').innerHTML =
    kpi('kw-k1', 'Class 1', n('public'), 'Free to use an external model') +
    kpi('kw-k2', 'Class 2', n('eu'), 'Kept on EU-hosted models') +
    kpi('kw-k3', 'Class 3', n('private'), "Kept in Kernwerk's datacenter") +
    kpi('kw-kstop', 'Stopped', stopped, 'No model received these') +
    kpi('save', 'Personal data replaced', items, 'In prompts and answers, before any model or person saw it');
}

let decisions = [];

function render() {
  const key = JSON.stringify(decisions) + [...open].join();
  if (key === last) return;
  last = key;
  kpis(decisions);
  el('rows').innerHTML = decisions.length
    ? decisions.map(row).join('')
    : '<tr><td colspan="6" class="dlp-empty">Nothing from Claude Desktop in the last 30 minutes.</td></tr>';
}

async function poll() {
  try {
    const e = await fetch('/api/dlp/events').then(r => r.json());
    el('dot').className = 'dot ' + (e.following ? 'live' : 'off');
    el('status-label').textContent = e.following ? 'following the gateway' : 'gateway logs not attached';
    decisions = e.decisions;
    render();
  } catch {
    el('dot').className = 'dot off';
    el('status-label').textContent = 'console only';
  }
  setTimeout(poll, 2000);
}

el('rows').addEventListener('click', e => {
  const tr = e.target.closest('tr.kw-row');
  if (!tr) return;
  open.has(tr.dataset.id) ? open.delete(tr.dataset.id) : open.add(tr.dataset.id);
  render();
});

poll();
