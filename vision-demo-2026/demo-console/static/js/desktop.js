// /desktop signs in as bob; /kernwerk/desktop is martink's story.
const USER = document.body.dataset.signin || 'bob';
const logEl = () => document.getElementById('log');
function logLine(t) {
  const el = logEl();
  el.insertAdjacentHTML('beforeend', `<div class="row in">${t}</div>`);
  el.scrollTop = el.scrollHeight;
}

function ago(ts) {
  if (!ts) return '—';
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (s < 90) return 'now';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  return Math.floor(s / 3600) + 'h ago';
}

function paint(s) {
  const fleet = s.fleet || {};
  const ov = fleet.overview || {};
  document.getElementById('kpis').innerHTML = `
    <div class="kpi"><div class="label">Devices</div><div class="value">${ov.total_devices ?? '—'}</div>
      <div class="hint">${ov.online_devices ?? 0} online</div></div>
    <div class="kpi"><div class="label">Policy revision</div><div class="value">${ov.active_revision ?? '—'}</div>
      <div class="hint">${ov.config_failures ?? 0} failed</div></div>
    <div class="kpi"><div class="label">Claude owner</div><div class="value" style="font-size:18px">${ownerLabel(s)}</div>
      <div class="hint">${s.enrol?.hostname || ''}</div></div>
    <div class="kpi ${s.agw?.on ? '' : 'save'}"><div class="label">EKS demo</div>
      <div class="value" style="font-size:18px">${s.agw?.on ? 'on' : 'off'}</div>
      <div class="hint">${s.agw?.native ? 'Claude is native' : (s.agw?.on ? 'release it before enrol' : 'clear for Agentdesktop')}</div></div>`;

  const tb = document.querySelector('#devices tbody');
  const devices = fleet.devices || [];
  tb.innerHTML = devices.map(d => `<tr>
    <td>${d.hostname || ''}</td>
    <td>${d.os || ''}</td>
    <td>${(d.installed_tools || []).join(', ') || '—'}</td>
    <td>${d.config_revision ?? ''}</td>
    <td>${ago(d.last_seen_at)}</td>
  </tr>`).join('') || '<tr><td colspan="5">No devices yet. The Linux fleet may still be starting.</td></tr>';

  const d = s.daemon || {};
  const codeManaged = d.code || (s.claude?.base_url || '').includes(s.gateway_host || 'agw.example.com');
  document.getElementById('laptop-cards').innerHTML = `
    <article class="budget ${d.running ? 'ok' : ''}"><div class="top"><h3>Agentdesktop daemon</h3>
      <span class="mode">${d.running ? 'running' : (d.installed ? 'installed, stopped' : 'not installed')}</span></div>
      <p class="note">${s.enrol?.hosts ? 'Names resolve.' : 'The sslip.io names do not resolve here.'} ${s.enrol?.binary ? 'Binary ready.' : 'Binary missing.'} Sign in as ${USER} / password.</p></article>
    <article class="budget ${codeManaged ? 'ok' : ''}"><div class="top"><h3>Claude Code</h3>
      <span class="mode">${d.code ? 'EKS gateway, managed' : ((s.claude?.base_url || '').includes(s.gateway_host || 'agw.example.com') ? 'EKS gateway' : (s.claude?.base_url ? 'other gateway' : 'native'))}</span></div>
      <p class="note">A managed settings file the machine owns, so your own ~/.claude/settings.json is left alone.</p></article>
    <article class="budget ${d.desktop ? 'ok' : ''}"><div class="top"><h3>Claude Desktop</h3>
      <span class="mode">${d.desktop ? 'EKS gateway' : (d.desktop_other ? 'agw-toggle owns it' : 'native')}</span></div>
      <p class="note">Desktop reads its policy from the machine's managed preferences, which is why step 1 asks for a password.</p></article>`;

  // Mark each step from the state on disk, so the flow is right after a reload too.
  const steps = {install: d.installed, signin: d.code || d.desktop, policy: d.desktop};
  for (const [name, done] of Object.entries(steps)) {
    const li = document.querySelector(`.flow li[data-step="${name}"]`);
    if (!li) continue;
    li.classList.toggle('done', !!done);
    li.classList.toggle('waiting', name !== 'install' && !d.installed);
  }

  const pol = s.policies || {};
  document.getElementById('policies').innerHTML = Object.entries(pol).map(([id, p]) => `
    <article class="budget ok">
      <div class="top"><h3>${p.label}</h3></div>
      <p class="note">${p.blurb}</p>
      <div class="edit"><button class="btn primary" data-policy="${id}">Apply</button></div>
    </article>`).join('');

  const c = s.claude || {};
  document.getElementById('claude-json').textContent = JSON.stringify({
    base_url: c.base_url || '(none)',
    apiKeyHelper: c.api_key_helper || '(none)',
    announcements: c.announcements || [],
    sandbox: c.sandbox || {},
  }, null, 2);

  const dot = document.getElementById('dot');
  const label = document.getElementById('status-label');
  if (fleet.ok) {
    dot.className = 'dot live';
    label.textContent = 'live · mesh1';
  } else {
    dot.className = 'dot off';
    label.textContent = fleet.error || 'controller not reachable';
  }
}

function ownerLabel(s) {
  const d = s.daemon || {};
  if (d.running && (d.code || d.desktop)) return 'Agentdesktop';
  if (s.agw?.on) return 'EKS demo';
  return 'nobody';
}

async function post(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  return r.json();
}

async function refresh() {
  const s = await fetch('/api/desktop/status').then(r => r.json());
  paint(s);
  return s;
}

async function boot() {
  await refresh();
  setInterval(refresh, 5000);
  const step = (id, url, note) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.onclick = async () => {
      el.disabled = true;
      logLine(note);
      const r = await post(url, { user: USER });
      logLine(r.error || r.text || JSON.stringify(r));
      el.disabled = false;
      await refresh();
    };
  };
  step('daemon-install', '/api/desktop/daemon-install',
       'Installing the daemon. macOS is asking for your password.');
  step('signin', '/api/desktop/signin',
       `Opening the identity provider. Sign in as ${USER} / password.`);
  step('daemon-remove', '/api/desktop/daemon-remove',
       'Removing the daemon. Both clients go back to native.');
  document.getElementById('enrol').onclick = async () => {
    logLine(`Starting Agentdesktop. Sign in as ${USER} / password in the browser.`);
    const r = await post('/api/desktop/enrol');
    logLine(r.error || r.text || JSON.stringify(r));
    await refresh();
  };
  document.getElementById('unenrol').onclick = async () => {
    logLine('Unenrolling. Claude Code returns to native.');
    const r = await post('/api/desktop/unenrol');
    logLine(r.text || (r.ok ? 'done' : r.error));
    await refresh();
  };
  document.getElementById('policies').addEventListener('click', async e => {
    const btn = e.target.closest('[data-policy]');
    if (!btn) return;
    logLine('Publishing policy: ' + btn.dataset.policy);
    const r = await post('/api/desktop/policy', { name: btn.dataset.policy });
    logLine(r.ok ? ('Published · ' + r.label) : (r.error || 'failed'));
    await refresh();
  });
}

boot();
