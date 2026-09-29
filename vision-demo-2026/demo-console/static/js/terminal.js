// The lab terminal dock: a real shell for this lab, kept alive across pages.
// Toggle with the bar or the ` key. Output streams from the server; keystrokes
// are posted back. Reconnecting replays the scrollback from the server's buffer.
(() => {
  const dock = document.getElementById('term-dock');
  if (!dock || !window.Terminal) return;
  const lab = dock.dataset.lab;
  const body = document.getElementById('term-body');
  const toggle = document.getElementById('term-toggle');
  const key = 'term-open-' + lab;
  const headers = { 'Content-Type': 'application/json', 'X-Term-Token': dock.dataset.token };
  let term, fit, offset = 0, gen = 0, pending = '', flushTimer = null, opened = false, shellId = '';

  dock.hidden = false;
  document.body.classList.add('has-term');

  // The token belongs to one console process. After a restart it is refused, so
  // fetch the new one (same-origin only) and carry on.
  async function refreshToken() {
    try {
      const r = await fetch('/api/term/token');
      if (r.ok) headers['X-Term-Token'] = (await r.json()).token;
    } catch { /* console still starting */ }
  }

  async function post(path, obj) {
    const req = () => fetch(path, { method: 'POST', headers, body: JSON.stringify({ lab, ...obj }) });
    let r = await req();
    if (r.status === 403) { await refreshToken(); r = await req(); }
    return r;
  }

  function send(data) {
    pending += data;
    if (!flushTimer) flushTimer = setTimeout(flush, 8);
  }

  function flush() {
    flushTimer = null;
    if (!pending) return;
    const data = pending;
    pending = '';
    post('/api/term/input', { data });
  }

  function b64decode(s) {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  // One live stream at a time: starting another (New shell, reopening the dock)
  // bumps gen, and the older loop notices and stops without touching the screen.
  async function stream() {
    const my = ++gen;
    while (my === gen) {
      try {
        const resp = await fetch(`/api/term/stream?lab=${encodeURIComponent(lab)}&from=${offset}&id=${shellId}`, { headers });
        if (my !== gen) return;
        if (resp.status === 403) { await refreshToken(); await new Promise(r => setTimeout(r, 1000)); continue; }  // the console restarted
        if (resp.status === 404) { await openShell(false); continue; }   // ...and has no shell yet
        if (!resp.ok) throw new Error(resp.status);
        const reader = resp.body.getReader();
        const dec = new TextDecoder();
        let buf = '';
        for (;;) {
          const { value, done } = await reader.read();
          if (done || my !== gen) break;
          buf += dec.decode(value, { stream: true });
          const lines = buf.split('\n');
          buf = lines.pop();
          for (const line of lines) {
            if (!line) continue;
            const ev = JSON.parse(line);
            if (ev.reset) { term.reset(); shellId = ev.id; }
            if (ev.d) term.write(b64decode(ev.d));
            offset = ev.o;
            if (ev.exit) {
              term.write('\r\n\x1b[2m[shell exited. Press New shell to start another.]\x1b[0m\r\n');
              return;
            }
          }
        }
      } catch (e) {
        await new Promise(r => setTimeout(r, 1500));
      }
    }
  }

  async function start(fresh) {
    if (!term) {
      term = new window.Terminal({
        cursorBlink: true, fontSize: 13, scrollback: 5000, convertEol: false,
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
        theme: { background: '#0f172a', foreground: '#e2e8f0', cursor: '#a78bfa', selectionBackground: '#334155' },
      });
      fit = new window.FitAddon.FitAddon();
      term.loadAddon(fit);
      // The fit addon sizes to its parent's height and ignores the parent's padding,
      // so the padding lives on the dock body and the terminal gets a bare inner box.
      const inner = document.createElement('div');
      inner.className = 'term-inner';
      body.appendChild(inner);
      term.open(inner);
      term.onData(send);
      new ResizeObserver(() => resize()).observe(body);
    }
    if (fresh) { term.reset(); offset = 0; }
    await openShell(!!fresh);
    resize();
    stream();
    term.focus();
  }

  // Keep trying until the console answers: it may be restarting under this page.
  async function openShell(fresh) {
    for (;;) {
      try {
        const r = await post('/api/term/open', { fresh });
        if (r.ok) { opened = true; resize(); return; }
      } catch { /* not up yet */ }
      await new Promise(res => setTimeout(res, 1500));
    }
  }

  let resizeTimer = null;
  function resize() {
    if (!term || !opened || dock.classList.contains('closed')) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      try { fit.fit(); } catch { return; }
      post('/api/term/resize', { cols: term.cols, rows: term.rows });
    }, 60);
  }

  function setOpen(open) {
    dock.classList.toggle('closed', !open);
    toggle.setAttribute('aria-expanded', String(open));
    document.body.classList.toggle('term-open', open);
    localStorage.setItem(key, open ? '1' : '0');
    if (open) start(false);
  }

  toggle.onclick = () => setOpen(dock.classList.contains('closed'));
  document.getElementById('term-new').onclick = () => { setOpen(true); start(true); };
  document.getElementById('term-max').onclick = () => { dock.classList.toggle('tall'); resize(); };
  document.addEventListener('keydown', e => {
    if (e.key !== '`' || e.metaKey || e.ctrlKey || e.altKey) return;
    if (dock.contains(document.activeElement)) return;            // typing a backtick in the shell
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    setOpen(dock.classList.contains('closed'));
  }, true);

  dock.classList.add('closed');
  if (localStorage.getItem(key) === '1') setOpen(true);
})();
