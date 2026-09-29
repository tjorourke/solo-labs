const el = id => document.getElementById(id);

let samples = [];
let shown = '';
const pinned = new URLSearchParams(location.search).get('id');

function pick(key) {
  const s = samples.find(x => x.key === key) || samples[0];
  document.querySelectorAll('#samples button').forEach(b => b.classList.toggle('active', b.dataset.sample === s.key));
  el('prompt').textContent = s.prompt;
  el('attach').innerHTML = s.file
    ? `In Claude Desktop, attach <code>${esc(s.file)}</code>, then paste this prompt.`
    : 'Paste this prompt into Claude Desktop.';
  el('copy').textContent = 'Copy prompt';
}

async function copy() {
  await navigator.clipboard.writeText(el('prompt').textContent);
  el('copy').textContent = 'Copied';
  setTimeout(() => { el('copy').textContent = 'Copy prompt'; }, 1500);
}

function show(d) {
  const key = d ? JSON.stringify([d.id, d.status, d.lane, d.masked, d.answer, d.answer_original]) : '';
  if (key === shown) return;
  shown = key;
  if (!d) return;
  const s = renderSummary(d);
  el('lanes').className = 'dlp-lanes' + (d.lane && s.cls !== 'stop' ? ' decided' : s.cls === 'stop' ? ' none' : '');
  document.querySelectorAll('.dlp-lane').forEach(l => l.classList.toggle('on', l.dataset.lane === d.lane));
  el('result').className = 'dlp-result ' + s.cls;
  el('result').innerHTML = `<div class="dlp-result-when">${pinned ? 'Prompt' : 'Latest prompt'} at ${stamp(d.ts)}`
    + (pinned ? ' · <a href="/kernwerk/dlp">follow the latest</a>' : '') + `</div>${s.html}`;
  el('more').hidden = false;
  el('flow').innerHTML = renderDecision(d).flow;
}

function tally(list) {
  const n = lane => list.filter(x => x.lane === lane && state(x) !== 'stopped').length;
  const stopped = list.filter(x => state(x) === 'stopped').length;
  const items = list.reduce((t, x) => t + (x.masked ? removals(x.prompt, x.masked).length : 0)
    + (x.answer_original && x.answer ? removals(x.answer_original, x.answer).length : 0), 0);
  el('tally').innerHTML = list.length
    ? `So far: <b>${n('public')}</b> Class 1 · <b>${n('eu')}</b> Class 2 · <b>${n('private')}</b> Class 3 · <b>${stopped}</b> stopped · <b>${items}</b> personal details removed <span>Every decision →</span>`
    : '';
}

async function poll() {
  try {
    const e = await fetch('/api/dlp/events').then(r => r.json());
    el('dot').className = 'dot ' + (e.following ? 'live' : 'off');
    el('status-label').textContent = e.following ? 'following the gateway' : 'gateway logs not attached';
    show(pinned ? e.decisions.find(d => d.id === pinned) : e.decisions[0]);
    tally(e.decisions);
  } catch {
    el('dot').className = 'dot off';
    el('status-label').textContent = 'console only';
  }
  setTimeout(poll, 2000);
}

async function init() {
  samples = await fetch('/api/dlp/samples').then(r => r.json());
  el('samples').innerHTML = samples.map(s => `<button data-sample="${esc(s.key)}">${esc(s.label)}</button>`).join('');
  document.querySelectorAll('#samples button').forEach(b => b.onclick = () => pick(b.dataset.sample));
  el('copy').onclick = copy;
  pick('public');
  fetch('/api/dlp/config').then(r => r.json()).then(c => {
    for (const k of ['lanes', 'routes', 'backends', 'policy', 'pii', 'desktop']) el('yaml-' + k).textContent = c[k];
  });
  poll();
}

init();
