const el = id => document.getElementById(id);
let running = false;
let board = '';

function setDot(id, cls, text) {
  el(id).className = 'dot ' + cls;
  el('sub-state').textContent = text;
}

function log(html, cls) {
  const box = el('sub-log');
  box.insertAdjacentHTML('beforeend', `<div class="row ${cls || ''}">${html}</div>`);
  box.scrollTop = box.scrollHeight;
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function mmss(sec) {
  sec = Math.max(0, Math.round(sec));
  return Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2, '0');
}

// The board only gets loaded once it is answering. Pointing an iframe at a dead
// port leaves a browser error page sitting in the middle of the demo.
function showBoard(url) {
  board = url;
  el('board-link').href = url;
  const frame = el('board');
  if (frame.dataset.src !== url) {
    frame.dataset.src = url;
    frame.src = url;
  }
}

async function status() {
  let s;
  try {
    s = await fetch('/api/substrate/status').then(r => r.json());
  } catch (e) {
    setDot('sub-dot', 'off', 'console only');
    return null;
  }
  el('m-actors').textContent = s.cluster ? `${s.ready}/${s.agents}` : '-';
  el('m-workers').textContent = s.cluster ? s.workers : '-';
  if (!s.cluster) {
    setDot('sub-dot', 'off', s.error || 'no substrate cluster');
  } else if (s.running) {
    setDot('sub-dot', 'live', 'chats running');
  } else {
    setDot('sub-dot', s.board_up ? 'live' : 'off', s.board_up ? 'board up, idle' : 'board not started');
  }
  if (s.board_up) showBoard(s.board);
  return s;
}

function busy(on) {
  running = on;
  el('go').disabled = on;
  el('pause').disabled = !on;
  el('go').textContent = on ? 'Running…' : 'Start the load';
}

async function start() {
  if (running) return;
  busy(true);
  el('sub-log').innerHTML = '';
  el('runbar').style.width = '0%';
  const body = {
    agents: Number(el('f-agents').value) || 12,
    workers: Number(el('f-workers').value) || 3,
    minutes: Number(el('f-minutes').value) || 2,
  };
  try {
    const resp = await fetch('/api/substrate/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
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
        handle(ev);
      }
    }
  } catch (e) {
    log(`<span class="bad">${esc(e)}</span>`);
  }
  busy(false);
  status();
}

function handle(ev) {
  if (ev.type === 'status') log(esc(ev.text), 'in');
  if (ev.type === 'line') {
    const bad = ev.text.startsWith('✗');
    log(`<span class="${bad ? 'bad' : ''}">${esc(ev.text)}</span>`);
  }
  if (ev.type === 'error') log(`<span class="bad">${esc(ev.text)}</span>`);
  if (ev.type === 'started') {
    showBoard(ev.board);
    log('watching the board', 'in');
  }
  if (ev.type === 'tick') {
    el('m-chats').textContent = ev.sent;
    el('m-left').textContent = mmss(ev.total - ev.elapsed);
    el('runbar').style.width = Math.min(100, (ev.elapsed / ev.total) * 100) + '%';
    if (ev.queued) el('m-chats').title = ev.queued + ' queued for a free worker';
  }
  if (ev.type === 'done') {
    el('m-left').textContent = '0:00';
    el('runbar').style.width = '100%';
    if (ev.ok) {
      log(`done · ${ev.sent} chats, ${ev.failed} failed. The board and the actors stay up.`, 'in');
    }
  }
}

async function pause() {
  el('pause').disabled = true;
  const r = await fetch('/api/substrate/pause', { method: 'POST' }).then(r => r.json());
  log(esc((r.output || '').trim().split('\n').pop() || 'chats stopped'), 'in');
  status();
}

async function teardown() {
  if (!confirm('Remove the load actors and stop the board?')) return;
  el('teardown').disabled = true;
  log('tearing down…', 'in');
  const r = await fetch('/api/substrate/stop', { method: 'POST' }).then(r => r.json());
  for (const line of (r.output || '').trim().split('\n')) if (line) log(esc(line));
  el('teardown').disabled = false;
  el('board').src = 'about:blank';
  el('board').dataset.src = '';
  status();
}

el('go').onclick = start;
el('pause').onclick = pause;
el('teardown').onclick = teardown;

fetch('/api/status').then(r => r.json()).then(s => {
  const dot = el('dot');
  const label = el('status-label');
  dot.className = 'dot ' + (s.decisions ? 'live' : 'off');
  label.textContent = s.context ? 'live · ' + s.context.split('/').pop() : 'console only';
}).catch(() => {});

status();
setInterval(() => { if (!running) status(); }, 6000);
