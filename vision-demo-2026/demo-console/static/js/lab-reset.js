(function () {
  const controls = [...document.querySelectorAll('[data-reset]')];
  let running = false;
  function clear(labs) {
    labs.forEach(lab => {
      const prefix = 'lab:v2:' + lab + ':';
      Object.keys(sessionStorage).filter(k => k.startsWith(prefix)).forEach(k => sessionStorage.removeItem(k));
    });
  }
  controls.forEach(control => {
    const button = control.querySelector('.lab-reset-go');
    const status = control.querySelector('.lab-reset-status');
    const out = control.querySelector('.lab-reset-output');
    button.addEventListener('click', async () => {
      if (running) return;
      running = true;
      controls.forEach(c => { c.querySelector('button').disabled = true; });
      out.hidden = false; out.textContent = '';
      status.textContent = 'Resetting. Waiting for resources to be removed…';
      let code = -1, failed = false, reader;
      const event = line => {
        if (!line.trim()) return;
        const ev = JSON.parse(line);
        if (ev.type === 'out' || ev.type === 'error') { out.textContent += ev.text + '\n'; out.scrollTop = out.scrollHeight; }
        if (ev.type === 'error') failed = true;
        if (ev.type === 'done') { code = ev.code; clear(ev.labs || []); }
      };
      try {
        const res = await fetch('/api/labs/reset', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ lab: control.dataset.reset }) });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        for (;;) {
          const { value, done } = await reader.read();
          if (done) { buffer += decoder.decode(); break; }
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n'); buffer = lines.pop(); lines.forEach(event);
        }
        event(buffer);
      } catch (e) { failed = true; out.textContent += e.message + '\n'; }
      finally { reader?.releaseLock(); running = false; controls.forEach(c => { c.querySelector('button').disabled = false; }); }
      status.textContent = code === 0 && !failed ? 'Reset complete. Clean state verified. You can start the lab again.' : 'Reset did not finish. Review the output and retry.';
      window.dispatchEvent(new Event('lab-reset'));
    });
  });
  window.addEventListener('beforeunload', e => { if (running) { e.preventDefault(); e.returnValue = ''; } });
})();
