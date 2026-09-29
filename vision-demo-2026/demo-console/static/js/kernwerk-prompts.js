const el = id => document.getElementById(id);
let groups = [];

// --- what actually happened -------------------------------------------------------
// The same decision feed the Gateway decisions page reads. A card is matched to a
// prompt on the text that was sent, ignoring whitespace, so a prompt pasted into Claude
// with a trailing newline still lines up with the row it came from.
const flat = s => String(s || '').replace(/\s+/g, ' ').trim().toLowerCase();
const seen = new Map();

function seenRow(p) {
  const d = seen.get(p.key);
  const L = KP_LANES[p.cls];
  if (!d) {
    return `<tr><td class="kp-prompt">${kpEsc(p.text.slice(0, 80))}</td>
      <td>${L.cls}</td><td>${kpEsc(p.expected)}</td>
      <td class="kp-waiting">not asked yet</td><td class="kp-waiting">–</td><td></td></tr>`;
  }
  const got = d.answered_by || (d.allowed === false ? 'no model' : '…');
  const ok = got === p.expected;
  return `<tr><td class="kp-prompt">${kpEsc(p.text.slice(0, 80))}</td>
    <td>${d.lane ? KP_LANES[d.lane].cls : '<span class="kp-waiting">none</span>'}</td>
    <td>${kpEsc(p.expected)}</td>
    <td class="${ok ? 'kp-match' : 'kp-mismatch'}">${kpEsc(got)}</td>
    <td>${d.replaced ? `<b>${d.replaced}</b> replaced` : '<span class="kp-waiting">none</span>'}</td>
    <td><a class="kw-open" href="/kernwerk/gateway-decisions">on the card →</a></td></tr>`;
}

function renderSeen() {
  const all = groups.flatMap(g => g.prompts);
  el('seen').textContent = seen.size;
  el('seen-rows').innerHTML = all.length ? all.map(seenRow).join('')
    : '<tr><td colspan="6" class="dlp-empty">Nothing asked yet.</td></tr>';
}

function onCard(c) {
  const text = flat(c.question || c.prompt || c.original);
  if (!text) return;
  for (const p of groups.flatMap(g => g.prompts)) {
    const want = flat(p.text);
    if (text === want || text.includes(want)) {
      const prev = seen.get(p.key);
      if (!prev || (c.ts || 0) >= (prev.ts || 0)) seen.set(p.key, c);
      renderSeen();
      return;
    }
  }
}

function listen() {
  const source = new EventSource('/events');
  source.onmessage = e => { try { onCard(JSON.parse(e.data)); } catch {} };
  source.onerror = () => {
    el('dot').className = 'dot off';
    el('status-label').textContent = 'gateway not attached';
  };
  source.onopen = () => {
    el('dot').className = 'dot live';
    el('status-label').textContent = 'following the gateway';
  };
}

document.querySelectorAll('.mcp-tab').forEach(t => {
  t.onclick = () => {
    document.querySelectorAll('.mcp-tab').forEach(x => x.classList.toggle('active', x === t));
    el('tab-prompts').hidden = t.dataset.tab !== 'prompts';
    el('tab-decisions').hidden = t.dataset.tab !== 'decisions';
  };
});

kpRender('groups', 'prompts').then(g => {
  groups = g;
  renderSeen();
  listen();
});
