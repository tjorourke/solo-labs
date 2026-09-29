// Guided notebook actions. The server owns commands; the browser sends only IDs.
(function () {
  const root = document.querySelector('.pr');
  if (!root) return;
  const { demo, step } = root.dataset;
  const story = JSON.parse(root.dataset.story);
  const key = s => 'lab:v2:' + demo + ':' + s;
  function generation(value) {
    if (sessionStorage.getItem(key('generation')) !== value) {
      Object.keys(sessionStorage).filter(k => k.startsWith(key(''))).forEach(k => sessionStorage.removeItem(k));
      sessionStorage.setItem(key('generation'), value);
    }
  }
  generation(root.dataset.generation);
  const ansi = window.nbAnsi || (t => esc(t));
  const cmds = [...root.querySelectorAll('.pr-cmd')];
  const out = document.getElementById('pr-out');
  const result = document.getElementById('pr-result');
  const message = document.getElementById('pr-run-message');
  const allButton = document.getElementById('pr-run-all');
  const tabBtns = [...root.querySelectorAll('.pr-tabs button')];
  let active = 0, running = false, queue = false, cancelled = false;

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  const runKey = i => key('run:' + step + ':' + i + ':' + cmds[i].dataset.revision);
  function saved(i) {
    try { return JSON.parse(sessionStorage.getItem(runKey(i)) || 'null'); }
    catch (_) { return null; }
  }
  function tab(name) {
    tabBtns.forEach(b => {
      b.classList.toggle('on', b.dataset.tab === name);
      b.setAttribute('aria-selected', String(b.dataset.tab === name));
    });
    root.querySelectorAll('.pr-pane').forEach(p => { p.hidden = p.dataset.pane !== name; });
    if (name === 'gloo') loadGloo();
    if (name === 'app') loadApp();
  }
  root.querySelectorAll('.pr-pane').forEach(p => {
    p.id = 'pane-' + p.dataset.pane;
    p.setAttribute('role', 'tabpanel');
  });
  tabBtns.forEach(b => b.addEventListener('click', () => tab(b.dataset.tab)));

  function paintProgress() {
    let done = 0;
    root.querySelectorAll('.pr-steps li').forEach(li => {
      const ok = sessionStorage.getItem(key('done:' + li.dataset.step)) === '1';
      li.classList.toggle('done', ok);
      if (ok) done++;
    });
    document.getElementById('pr-bar').style.width = (100 * done / story.length) + '%';
    document.getElementById('pr-count').textContent = done + ' of ' + story.length + ' chapters complete';
    const count = cmds.filter((_, i) => saved(i)?.state === 'ok').length;
    document.getElementById('pr-action-count').textContent = cmds.length ? count + ' of ' + cmds.length + ' steps passed' : 'Reference';
    if (allButton) allButton.disabled = running || queue;
    cmds.forEach((box, i) => {
      // Run in order. Earlier actions remain available for retry; rerunning one
      // invalidates the later results, since those checks describe older state.
      box.querySelector('.pr-go').disabled = running || queue || cmds.slice(0, i).some((_, n) => saved(n)?.state !== 'ok');
    });
  }
  function setState(box, state) {
    const chip = box.querySelector('.pr-state');
    chip.hidden = !state;
    chip.className = 'pr-state ' + (state || '');
    chip.textContent = ({ ok: 'Passed', warn: 'Review', bad: 'Failed', running: 'Running' })[state] || '';
    box.classList.remove('ok', 'bad', 'warn', 'running');
    if (state) box.classList.add(state);
  }
  function renderResult() {
    const box = cmds[active];
    if (!box) {
      result.innerHTML = '<p class="pr-empty">This chapter has no commands. Review the background notes.</p>';
      return;
    }
    const r = saved(active);
    if (!r) {
      result.innerHTML = '<div class="pr-verdict pending"><h3>Step ' + (active + 1) + ': ' + esc(box.querySelector('.pr-cmd-title').textContent) + '</h3><p>' + esc(box.querySelector('.pr-instruction').textContent) + '</p><p><b>Expected result</b><br>' + esc(box.querySelector('.pr-expect').lastChild.textContent) + '</p><p class="pr-empty">Not run yet.</p></div>';
      out.textContent = 'No output for this step yet.';
      return;
    }
    const rows = r.rows.map(x => '<li class="' + x.state + '"><i></i><span class="l">' + esc(x.label) + '</span>' + (x.value ? '<code>' + esc(x.value) + '</code>' : '') + '</li>').join('');
    result.innerHTML = '<div class="pr-verdict ' + r.state + '"><h3>Step ' + (active + 1) + ': ' + esc(box.querySelector('.pr-cmd-title').textContent) + '</h3><ul>' + rows + '</ul></div>';
    out.innerHTML = ansi(r.text);
  }
  function select(i) {
    if (running || !cmds[i]) return;
    active = i;
    cmds.forEach((box, n) => {
      box.classList.toggle('current', n === i);
      box.querySelector('.pr-cmd-body').hidden = n !== i;
      box.querySelector('.pr-cmd-head').setAttribute('aria-expanded', String(n === i));
    });
    root.querySelectorAll('[data-script]').forEach(p => { p.hidden = Number(p.dataset.script) !== i; });
    renderResult();
  }
  function evaluate(checks, text, code) {
    const rows = checks.map(c => {
      let t = text, found = true;
      if (c.from) { const i = t.indexOf(c.from); found = i >= 0; t = found ? t.slice(i + c.from.length) : ''; }
      if (c.to) { const i = t.indexOf(c.to); found = found && i >= 0; t = i >= 0 ? t.slice(0, i) : ''; }
      const hit = new RegExp(c.match, 'm').test(t);
      const pass = found && (c.absent ? !hit : hit);
      const m = c.value && new RegExp(c.value, 'm').exec(t);
      const value = m ? (m[1] || m[0]).trim() : '';
      if (code === 0 && pass && c.save && value) sessionStorage.setItem(key(c.save), value);
      return { label: c.label, value, state: pass ? 'ok' : c.warn ? 'warn' : 'bad' };
    });
    if (!rows.length || code !== 0) rows.push({ label: 'Command exit status', value: String(code), state: code === 0 ? 'ok' : 'bad' });
    return rows;
  }
  function invalidateFrom(i) {
    cmds.slice(i).forEach((box, n) => { sessionStorage.removeItem(runKey(i + n)); setState(box, ''); });
    story.slice(story.indexOf(step)).forEach(s => sessionStorage.removeItem(key('done:' + s)));
    story.slice(story.indexOf(step) + 1).forEach(s => {
      Object.keys(sessionStorage).filter(k => k.startsWith(key('run:' + s + ':'))).forEach(k => sessionStorage.removeItem(k));
    });
  }
  async function run(i) {
    if (running) return false;
    try {
      const res = await fetch('/api/labs/state');
      if (!res.ok) throw new Error('Could not check lab state');
      const state = await res.json();
      if (state[demo] !== sessionStorage.getItem(key('generation'))) {
        generation(state[demo]);
        cmds.forEach(box => setState(box, ''));
        paintProgress(); renderResult();
        message.textContent = 'The lab was reset. Start again from the first chapter.';
        return false;
      }
    } catch (e) { message.textContent = e.message; return false; }
    if (running) return false;
    select(i);
    const box = cmds[i];
    invalidateFrom(i);
    running = true;
    box.querySelector('.pr-stop').disabled = false;
    setState(box, 'running');
    message.textContent = 'Running step ' + (i + 1) + ' of ' + cmds.length + '.';
    paintProgress();
    out.innerHTML = '';
    // If you are watching a live view (App, Gloo UI), stay on it. Otherwise a step
    // can name the tab to watch it on; the default is its output.
    const current = tabBtns.find(b => b.classList.contains('on'))?.dataset.tab;
    const stay = current === 'app' || current === 'gloo';
    const watch = stay ? current : box.dataset.watch;
    tab(watch && tabBtns.some(b => b.dataset.tab === watch) ? watch : 'output');
    let text = '', code = -1, error = false, reader;
    const append = t => {
      text += t + '\n';
      out.insertAdjacentHTML('beforeend', ansi(t) + '\n');
      out.scrollTop = out.scrollHeight;
    };
    const event = line => {
      if (!line.trim()) return;
      const ev = JSON.parse(line);
      if (ev.type === 'out' || ev.type === 'error') append(ev.text);
      if (ev.type === 'error') error = true;
      if (ev.type === 'done') code = ev.code;
    };
    try {
      const res = await fetch('/api/notebook/run', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ demo, step, index: Number(box.dataset.index), part: Number(box.dataset.part), revision: box.dataset.revision,
          params: Object.fromEntries([...box.querySelectorAll('[data-param]')].map(i => [i.dataset.param, i.value])) })
      });
      if (!res.ok) throw new Error('Run request failed: HTTP ' + res.status);
      reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) { buf += decoder.decode(); break; }
        buf += decoder.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop();
        lines.forEach(event);
      }
      event(buf);
    } catch (e) { error = true; append('Console: ' + e.message); }
    finally { reader?.releaseLock(); }
    const rows = evaluate(JSON.parse(box.dataset.checks), text.replace(/\x1b\[[0-9;]*m/g, ''), error || cancelled ? -1 : code);
    const state = rows.some(r => r.state === 'bad') ? 'bad' : rows.some(r => r.state === 'warn') ? 'warn' : 'ok';
    sessionStorage.setItem(runKey(i), JSON.stringify({ rows, state, text }));
    setState(box, state);
    box.querySelector('.pr-stop').disabled = true;
    running = false;
    const complete = cmds.every((_, n) => saved(n)?.state === 'ok');
    if (complete) sessionStorage.setItem(key('done:' + step), '1');
    message.textContent = cancelled ? 'Stopped. Later steps have not run.' : state !== 'ok' ? 'Stopped at step ' + (i + 1) + '. Review the checks and output, then retry.' : complete ? 'All steps passed. Continue to the next chapter.' : 'Step ' + (i + 1) + ' passed. Select step ' + (i + 2) + ' to continue.';
    renderResult();
    paintProgress();
    // never pull someone off a live view; a watched step stays put when it passes
    if (stay) tab(current);
    else tab(watch && watch !== 'output' && state === 'ok' && !cancelled && tabBtns.some(b => b.dataset.tab === watch) ? watch : 'result');
    return state === 'ok' && !cancelled;
  }
  cmds.forEach((box, i) => {
    setState(box, saved(i)?.state);
    box.querySelector('.pr-cmd-head').addEventListener('click', () => select(i));
    box.querySelector('.pr-code').addEventListener('click', () => { select(i); tab('script'); });
    box.querySelector('.pr-go').addEventListener('click', async () => {
      if (queue) return;
      cancelled = false;
      await run(i);
    });
    box.querySelector('.pr-stop').addEventListener('click', async () => {
      cancelled = true;
      box.querySelector('.pr-stop').disabled = true;
      try {
        const res = await fetch('/api/notebook/stop', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ demo, step, index: Number(box.dataset.index) }) });
        if (!res.ok) throw new Error('HTTP ' + res.status);
      } catch (e) { message.textContent = 'Could not stop the command: ' + e.message; }
    });
  });
  allButton?.addEventListener('click', async () => {
    if (running || queue) return;
    queue = true; cancelled = false;
    try {
      for (let i = 0; i < cmds.length; i++) {
        if (saved(i)?.state === 'ok') continue;
        if (cancelled || !await run(i)) break;
      }
    } finally { queue = false; paintProgress(); }
  });
  document.getElementById('pr-read')?.addEventListener('click', e => {
    sessionStorage.setItem(key('done:' + step), '1');
    e.target.textContent = 'Read'; paintProgress();
  });
  async function loadGloo() {
    const f = root.querySelector('iframe[data-console="gloo-ui"]');
    if (!f || f.src) return;
    try {
      const r = await fetch('/api/notebook/console', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ demo, console: 'gloo-ui' }) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error);
      f.src = j.url;
    } catch (e) { f.srcdoc = '<p style="font:14px system-ui;padding:20px">Gloo UI: ' + esc(e.message) + '</p>'; }
  }
  function loadApp() {
    const f = document.getElementById('pr-app');
    if (!f) return;
    // A lab either saves its app's address from a step's output, or names a fixed one.
    const url = sessionStorage.getItem(key('app')) || f.dataset.url;
    const valid = url && /^(https?:\/\/|\/)/.test(url);
    f.hidden = !valid;
    document.getElementById('pr-app-empty').hidden = !!valid;
    if (!valid) return;
    document.getElementById('pr-app-open').href = url;
    document.getElementById('pr-app-label').textContent = url;
    if (f.src !== url) f.src = url;
  }
  document.getElementById('pr-app-reload')?.addEventListener('click', () => {
    loadApp(); const f = document.getElementById('pr-app'); if (f.src) f.src = f.src;
  });
  root.querySelectorAll('.pr-copy').forEach(b => b.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(b.closest('.pr-script').querySelector('code').textContent); b.textContent = 'Copied'; }
    catch (_) { b.textContent = 'Select and copy the commands'; }
    setTimeout(() => { b.textContent = 'Copy'; }, 1500);
  }));
  document.addEventListener('click', e => {
    if ((running || queue) && e.target.closest('a')?.getAttribute('href')?.startsWith('/')) {
      e.preventDefault(); message.textContent = 'Wait for the running step, or stop it before leaving this chapter.';
    }
  });
  window.addEventListener('beforeunload', e => { if (running || queue) { e.preventDefault(); e.returnValue = ''; } });
  document.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey || /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) return;
    const k = e.key;
    if (!running && !queue && (k === 'ArrowRight' || k === 'ArrowLeft')) document.getElementById(k === 'ArrowRight' ? 'pr-next' : 'pr-prev')?.click();
    else if (k === 'Enter' && !/^(BUTTON|A|SUMMARY)$/.test(document.activeElement.tagName)) { e.preventDefault(); cmds[active]?.querySelector('.pr-go').click(); }
    else if (k.toLowerCase() === 'n') { const d = document.getElementById('pr-notes'); d.open = !d.open; }
    else if (k.toLowerCase() === 'f') { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen(); }
    else if (/^[1-9]$/.test(k) && tabBtns[Number(k) - 1]) tab(tabBtns[Number(k) - 1].dataset.tab);
  });
  select(Math.max(0, cmds.findIndex((_, i) => saved(i)?.state !== 'ok')));
  paintProgress(); renderResult();
  window.addEventListener('lab-reset', () => { paintProgress(); renderResult(); });
})();
