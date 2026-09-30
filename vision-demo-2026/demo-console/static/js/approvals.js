// The platform admin's screen. Same grant the wizard used to do inline on /agents,
// taken out of the builder's hands so the two jobs are visibly two jobs.
let agents = [];
let catalog = { mcp: [] };
let selected = null;
let mode = 'approve';

const el = id => document.getElementById(id);
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Only servers without the auto-approve label come to this screen. The rest were granted
// at deploy and are listed under "Allowed automatically".
const isAuto = id => !!((catalog.mcp || []).find(x => x.id === id) || {}).autoApprove;

function allGroups(a) {
  return (a.mcp || []).filter(m => (m.tools || []).length).map(m => {
    const server = (catalog.mcp || []).find(x => x.id === m.id);
    return { id: m.id, name: server ? server.name : m.id, tools: m.tools };
  });
}

const mcpGroups = a => allGroups(a).filter(g => !isAuto(g.id));
const autoGroups = a => allGroups(a).filter(g => isAuto(g.id));
const toolCount = a => mcpGroups(a).reduce((n, g) => n + g.tools.length, 0);
const approved = a => !!(a && (a.admin_approved || a.mcp_approved || a.github_approved));

function card(a, isApproved) {
  const n = toolCount(a);
  const groups = mcpGroups(a);
  const yaml = isApproved ? (a.policy_yaml || '') : (a.policy_preview || '');
  return `
    <div class="agent-card">
      <div class="kicker">${isApproved ? 'Security · approved' : 'Security · platform admin'}</div>
      <h3>${esc(a.name)}${a.version ? ' · ' + esc(a.version) : ''}</h3>
      <p class="sub">Identity <code>kagent/${esc(a.name)}</code> · ${n} tool${n === 1 ? '' : 's'}
        across ${groups.length} server${groups.length === 1 ? '' : 's'}.</p>
      <p class="sub">${groups.map(g => `${esc(g.name)} (${g.tools.length})`).join(', ') || 'none'}</p>
      <div class="card-actions">
        <button class="btn ${isApproved ? '' : 'primary'}" data-act="${isApproved ? 'revoke' : 'approve'}"
                data-name="${esc(a.name)}">${isApproved ? 'Revoke MCP access' : 'Review MCP tools'}</button>
      </div>
      <details class="yaml" style="margin-top:10px">
        <summary>${isApproved ? 'The policy in force' : 'The policy this would write'}</summary>
        <pre>${esc(yaml || 'No MCP tools requested.')}</pre>
      </details>
    </div>`;
}

function autoCard(a) {
  const groups = autoGroups(a);
  return `
    <div class="agent-card auto-card">
      <div class="kicker ok">Granted automatically</div>
      <h3>${esc(a.name)}${a.version ? ' · ' + esc(a.version) : ''}</h3>
      <p class="sub">${groups.map(g => `${esc(g.name)} (${g.tools.length})`).join(', ')}</p>
      <p class="sub">Labelled <code>${esc(catalog.autoApproveLabel || '')}=true</code> in AgentRegistry. The grant for
        <code>kagent/${esc(a.name)}</code> was written at deploy, with only the tools it picked.</p>
      <details class="yaml" style="margin-top:10px">
        <summary>The policy in force</summary>
        <pre>${esc(a.auto_policy_yaml || 'No gateway policy for these servers.')}</pre>
      </details>
    </div>`;
}

function paint() {
  const autos = agents.filter(a => a.applied && autoGroups(a).length);
  el('auto').innerHTML = autos.map(autoCard).join('');
  el('auto-empty').style.display = autos.length ? 'none' : 'block';
  const waiting = agents.filter(a => a.applied && mcpGroups(a).length && !approved(a));
  const done = agents.filter(a => mcpGroups(a).length && approved(a));
  el('pending').innerHTML = waiting.map(a => card(a, false)).join('');
  el('allowed').innerHTML = done.map(a => card(a, true)).join('');
  el('pending-empty').style.display = waiting.length ? 'none' : 'block';
  el('allowed-empty').style.display = done.length ? 'none' : 'block';
  el('ap-dot').className = 'dot ' + (waiting.length ? 'warn' : 'live');
  el('ap-state').textContent = waiting.length
    ? waiting.length + ' waiting'
    : (done.length ? 'all approved' : 'nothing deployed');
  for (const b of document.querySelectorAll('[data-act]')) {
    b.onclick = () => openModal(b.dataset.name, b.dataset.act);
  }
}

function openModal(name, m) {
  const a = agents.find(x => x.name === name);
  if (!a) return;
  selected = name;
  mode = m;
  const groups = mcpGroups(a);
  el('mcp-modal-who').textContent = 'Identity kagent/' + a.name + (a.version ? ' · ' + a.version : '');
  el('mcp-modal-tools').innerHTML = groups.length
    ? groups.map(g => `<h4>${esc(g.name)} · ${g.tools.length}</h4><ul>${g.tools.map(t => `<li>${esc(t)}</li>`).join('')}</ul>`).join('')
    : '<p class="sub">No tools requested.</p>';
  el('mcp-modal-yaml').textContent = (m === 'revoke' ? a.policy_yaml : a.policy_preview) || 'No policy for this agent.';
  el('mcp-modal-msg').textContent = '';
  if (m === 'revoke') {
    el('mcp-modal-kicker').textContent = 'Security · revoke';
    el('mcp-modal-title').textContent = 'Revoke MCP tools';
    el('mcp-modal-lead').textContent = 'These tools are currently allowed for this identity. Revoke to deny them again.';
    el('mcp-modal-approve').style.display = 'none';
    el('mcp-modal-deny').textContent = 'Revoke';
  } else {
    el('mcp-modal-kicker').textContent = 'Security · platform admin';
    el('mcp-modal-title').textContent = 'Approve MCP tools';
    el('mcp-modal-lead').textContent = 'This identity is asking for the tools below. Approve or deny the lot.';
    el('mcp-modal-approve').style.display = '';
    el('mcp-modal-deny').textContent = 'Deny';
  }
  el('mcp-modal').style.display = 'flex';
}

function closeModal() {
  el('mcp-modal').style.display = 'none';
  selected = null;
}

async function act(path, working, done) {
  if (!selected) return;
  const msg = el('mcp-modal-msg');
  msg.textContent = working;
  el('mcp-modal-approve').disabled = true;
  el('mcp-modal-deny').disabled = true;
  try {
    const r = await fetch('/api/agents/' + encodeURIComponent(selected) + path, { method: 'POST' })
      .then(r => r.json());
    msg.textContent = r.ok ? done : (r.error || 'that did not work');
    await load();
    if (r.ok) setTimeout(closeModal, 900);
  } catch (e) {
    msg.textContent = String(e);
  }
  el('mcp-modal-approve').disabled = false;
  el('mcp-modal-deny').disabled = false;
}

const approve = () => act('/approve-github', 'writing the policy…', 'Approved. The gateway is allowing these tools now.');
const revoke = () => {
  if (mode === 'revoke') return act('/revoke-github', 'taking it back out…', 'Revoked. The identity is denied again.');
  closeModal();
};

async function load() {
  const [cat, list] = await Promise.all([
    fetch('/api/agents/catalog').then(r => r.json()).catch(() => ({ mcp: [] })),
    fetch('/api/agents').then(r => r.json()).catch(() => ({ agents: [] })),
  ]);
  catalog = cat;
  agents = list.agents || [];
  paint();
}

el('mcp-modal-approve').onclick = approve;
el('mcp-modal-deny').onclick = revoke;
el('mcp-modal-close').onclick = closeModal;
el('mcp-modal').onclick = e => { if (e.target.id === 'mcp-modal') closeModal(); };

fetch('/api/status').then(r => r.json()).then(s => {
  el('dot').className = 'dot ' + (s.decisions ? 'live' : 'off');
  el('status-label').textContent = s.context ? 'live · ' + s.context.split('/').pop() : 'console only';
}).catch(() => {});

load();
setInterval(() => { if (el('mcp-modal').style.display === 'none') load(); }, 8000);
