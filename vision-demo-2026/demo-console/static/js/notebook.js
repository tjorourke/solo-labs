// Run one notebook cell from the page and stream its output back.
//
// The page never sends bash. It sends which demo, which step and which block,
// and the server runs whatever the notebook holds at that position.
(function () {
  document.querySelectorAll('.nb-run').forEach(setup);

  // The cells colour their own output with SGR escapes. Keep the colour, since
  // green and red are half of what the step is saying, and drop everything else.
  const SGR = {
    1: 'b', 30: 'c-blk', 31: 'c-red', 32: 'c-grn', 33: 'c-yel',
    34: 'c-blu', 35: 'c-mag', 36: 'c-cyn', 37: 'c-wht', 90: 'c-dim'
  };

  function ansi(text) {
    let out = '';
    let open = 0;
    const re = /\x1b\[([0-9;]*)m/g;
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      out += esc(text.slice(last, m.index));
      last = re.lastIndex;
      const codes = (m[1] || '0').split(';').map(Number);
      for (const c of codes) {
        if (c === 0) { out += '</span>'.repeat(open); open = 0; continue; }
        const cls = SGR[c];
        if (cls) { out += '<span class="' + cls + '">'; open++; }
      }
    }
    out += esc(text.slice(last));
    return out + '</span>'.repeat(open);
  }

  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  window.nbAnsi = ansi;   // so the colour handling can be checked on its own

  // "Open Gloo UI" and friends: port-forward on demand, then open the tab.
  document.querySelectorAll('.nb-console').forEach(btn => {
    btn.addEventListener('click', async () => {
      const msg = document.getElementById('console-msg');
      const label = btn.textContent;
      btn.disabled = true;
      btn.textContent = 'Opening…';
      if (msg) msg.textContent = '';
      try {
        const r = await fetch('/api/notebook/console', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ demo: btn.dataset.demo, console: btn.dataset.console })
        });
        const j = await r.json();
        if (j.ok) window.open(j.url, '_blank', 'noreferrer');
        else if (msg) msg.textContent = label + ': ' + j.error;
      } catch (e) {
        if (msg) msg.textContent = label + ': ' + e.message;
      } finally {
        btn.disabled = false;
        btn.textContent = label;
      }
    });
  });

  function setup(box) {
    const demo = box.dataset.demo;
    const step = box.dataset.step;
    const index = Number(box.dataset.index);
    const go = box.querySelector('.nb-go');
    const stop = box.querySelector('.nb-stop');
    const copy = box.querySelector('.nb-copy');
    const out = box.querySelector('.nb-out');
    const code = box.querySelector('.nb-code code');

    copy.addEventListener('click', () => {
      navigator.clipboard.writeText(code.textContent).then(() => {
        copy.textContent = 'Copied';
        setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
      });
    });

    stop.addEventListener('click', () => {
      stop.disabled = true;
      fetch('/api/notebook/stop', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ demo, step, index })
      });
    });

    go.addEventListener('click', async () => {
      go.disabled = true;
      stop.disabled = false;
      box.classList.remove('ok', 'bad');
      box.classList.add('running');
      out.hidden = false;
      out.textContent = '';

      try {
        const res = await fetch('/api/notebook/run', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ demo, step, index })
        });
        const reader = res.body.getReader();
        const dec = new TextDecoder();
        let buf = '';
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += dec.decode(value, { stream: true });
          const lines = buf.split('\n');
          buf = lines.pop();
          lines.filter(Boolean).forEach(l => handle(JSON.parse(l)));
        }
      } catch (e) {
        append('console: ' + e.message);
        box.classList.add('bad');
      } finally {
        go.disabled = false;
        stop.disabled = true;
        box.classList.remove('running');
      }
    });

    function handle(ev) {
      if (ev.type === 'out') return append(ev.text);
      if (ev.type === 'error') { append(ev.text); box.classList.add('bad'); return; }
      if (ev.type === 'done') {
        box.classList.add(ev.code === 0 ? 'ok' : 'bad');
        append(ev.code === 0 ? '\n✓ done' : '\n✗ exit ' + ev.code);
      }
    }

    function append(text) {
      const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 24;
      out.insertAdjacentHTML('beforeend', (out.innerHTML ? '\n' : '') + ansi(text));
      if (atBottom) out.scrollTop = out.scrollHeight;
    }
  }
})();
