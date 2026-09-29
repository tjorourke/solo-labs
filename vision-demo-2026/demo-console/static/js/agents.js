let catalog = { skills: [], mcp: [], platform: {} };
let agents = [];
let prompts = [];
let selected = null;
let mcpPicked = {};
let mcpTab = null;
let wizStep = 1;
let editing = false;

const DEMO = {
  description: 'Release briefing for open slice-manager pull requests and telco tickets.',
  prompt: `You are the network-slice-manager copilot for an EMEA telco platform team.

When asked for a release report or open work, use GitHub on tjorourke/network-slice-manager. List open pull requests, read status, reviews and labels, and classify each as ready to merge, needs work, or do not merge. Prefer the labels ready-to-merge, needs-work and do-not-merge when they are present.

Keep the answer as a short briefing, not a dump. Use only the tools you have been given. Do not merge, comment or write.

Only report what a tool returned in this conversation. If you have no GitHub tools, or a call fails or is denied, say "I can't read GitHub yet: <the reason>. A platform admin has to approve my GitHub access." and stop. Never invent pull request numbers, titles, reviews or labels, and never show example or placeholder data.`,
  skills: ['github-briefing'],
  githubTools: [
    'list_pull_requests', 'pull_request_read', 'get_pull_request',
    'get_pull_request_files', 'get_pull_request_reviews',
    'get_pull_request_comments', 'get_pull_request_status',
    'list_issues', 'get_issue', 'search_issues', 'get_file_contents',
    'search_code', 'get_repository',
  ],
};

async function boot() {
  const cat = await fetch('/api/agents/catalog').then(r => r.json());
  catalog = cat;
  paintPlatform();
  paintForm();
  await refreshList();
  document.getElementById('deploy').onclick = deploy;
  document.getElementById('new-agent').onclick = startNew;
  document.getElementById('detail-close').onclick = closeDetail;
  document.getElementById('detail-edit').onclick = () => { if (selected) loadIntoForm(selected); };
  document.getElementById('detail-del').onclick = () => { if (selected) remove(selected); };
  document.getElementById('wiz-next').onclick = wizNext;
  document.getElementById('wiz-back').onclick = wizBack;
  document.getElementById('wiz-cancel').onclick = showHome;
  document.getElementById('wiz-nav').onclick = e => {
    const li = e.target.closest('[data-goto]');
    if (!li) return;
    const n = parseInt(li.dataset.goto, 10);
    if (n >= 1 && n <= 4) goStep(n);
  };
  document.getElementById('prompt-load').onclick = pullPrompt;
  document.getElementById('new-skill').onclick = openSkillModal;
  document.getElementById('skill-cancel').onclick = closeSkillModal;
  document.getElementById('skill-save').onclick = saveSkill;
  document.getElementById('skill-title').oninput = paintSkillTarget;
  showHome();
  loadPrompts();
}

// The registry read is not on the critical path: the wizard works with the box typed by
// hand, so a slow or absent registry must not hold the page up.
async function loadPrompts() {
  const sel = document.getElementById('prompt-pick');
  try {
    const r = await fetch('/api/agents/prompts').then(x => x.json());
    prompts = r.prompts || [];
  } catch (e) {
    prompts = [];
  }
  if (!prompts.length) {
    sel.innerHTML = '<option value="">No prompts in the registry</option>';
    return;
  }
  const opt = p => `<option value="${p.id}|${p.tag}">${p.id} · ${p.tag}${p.description ? ' — ' + p.description : ''}</option>`;
  const standalone = prompts.filter(p => !p.generated);
  const fromAgents = prompts.filter(p => p.generated);
  sel.innerHTML = '<option value="">Choose a prompt…</option>'
    + (standalone.length ? `<optgroup label="In the registry">${standalone.map(opt).join('')}</optgroup>` : '')
    + (fromAgents.length ? `<optgroup label="From an agent">${fromAgents.map(opt).join('')}</optgroup>` : '');
}

function pullPrompt() {
  const v = document.getElementById('prompt-pick').value;
  const msg = document.getElementById('form-msg');
  if (!v) { msg.textContent = 'Choose a prompt first.'; return; }
  const [id, tag] = v.split('|');
  const p = prompts.find(x => x.id === id && x.tag === tag);
  if (!p) { msg.textContent = 'That prompt is no longer in the registry.'; return; }
  document.getElementById('prompt').value = p.content || '';
  msg.textContent = `Pulled ${p.id}:${p.tag} from AgentRegistry. Edit it freely.`;
}

function paintPlatform() {
  const p = catalog.platform || {};
  const dot = document.getElementById('dot');
  const label = document.getElementById('status-label');
  const note = document.getElementById('platform-note');
  if (p.kagent) {
    dot.className = 'dot live';
    label.textContent = 'kagent on mesh1';
  } else {
    dot.className = 'dot off';
    label.textContent = 'YAML only · kagent not installed';
  }
  let html = p.note ? p.note : 'Saved here, published to the registry, then deployed on kagent. When the last step is green, prompt it.';
  note.innerHTML = html;
  const k = document.getElementById('btn-kagent');
  const r = document.getElementById('btn-registry');
  if (p.ui) { k.href = p.ui.replace(/\/$/, '') + '/agents'; k.style.display = ''; }
  else k.style.display = 'none';
  if (p.registry_ui) { r.href = p.registry_ui; r.style.display = ''; }
  else r.style.display = 'none';
}

function toolId(t) { return typeof t === 'string' ? t : t.id; }
function toolDesc(t) { return typeof t === 'string' ? '' : (t.description || ''); }

function pickedSkill() {
  const el = document.querySelector('[data-skill]:checked');
  return el ? el.dataset.skill : '';
}

// Radios, not checkboxes: one skill shapes one agent. "No skill" is a row of its own so
// the choice can be cleared without hunting for the chip.
function paintSkills() {
  const chosen = pickedSkill();
  const picked = catalog.skills.find(s => s.id === chosen);
  const chips = picked
    ? `<span class="skill-chip">${picked.title}<button type="button" data-unpick="1" aria-label="Remove">×</button></span>`
    : '<span class="sub">No skill</span>';
  document.getElementById('skills').innerHTML = `
    <div class="skill-picker">
      <div class="skill-chips">${chips}</div>
      <div class="skill-list">
        <label class="skill-row ${chosen ? '' : 'on'}">
          <input type="radio" name="wiz-skill" data-skill="" ${chosen ? '' : 'checked'}>
          <span>
            <span class="meta"><strong>No skill</strong></span>
            <p>The prompt on its own.</p>
          </span>
        </label>
        ${catalog.skills.map(s => `
          <label class="skill-row ${chosen === s.id ? 'on' : ''}">
            <input type="radio" name="wiz-skill" data-skill="${s.id}" ${chosen === s.id ? 'checked' : ''}>
            <span>
              <span class="meta"><strong>${s.title}</strong><span class="dom">${s.domain || ''}${s.ready === false ? ' · not ready in registry' : ''}</span></span>
              <p>${s.description}</p>
            </span>
          </label>`).join('')}
      </div>
    </div>`;
}

function selectSkill(id) {
  const el = document.querySelector(`[data-skill="${id || ''}"]`);
  if (el) el.checked = true;
  paintSkills();
}

function paintForm() {
  paintSkills();
  document.getElementById('skills').addEventListener('change', e => {
    if (e.target.matches('[data-skill]')) paintSkills();
  });
  document.getElementById('skills').addEventListener('click', e => {
    if (!e.target.closest('[data-unpick]')) return;
    selectSkill('');
  });
  if (!mcpTab && catalog.mcp.length) mcpTab = catalog.mcp[0].id;
  catalog.mcp.forEach(m => {
    if (!mcpPicked[m.id]) mcpPicked[m.id] = new Set();
  });
  paintMcp();
  document.getElementById('mcp').onclick = onMcpClick;
  applyDemo();
}

function pickedFor(id) {
  if (!mcpPicked[id]) mcpPicked[id] = new Set();
  return mcpPicked[id];
}

function paintMcp() {
  const servers = catalog.mcp || [];
  if (!servers.length) { document.getElementById('mcp').innerHTML = ''; return; }
  if (!servers.some(s => s.id === mcpTab)) mcpTab = servers[0].id;
  const active = servers.find(s => s.id === mcpTab) || servers[0];
  const picked = pickedFor(active.id);
  document.getElementById('mcp').innerHTML = `
    <div class="mcp-split">
      <div class="mcp-nav">
        ${servers.map(s => {
          const n = pickedFor(s.id).size;
          return `<button type="button" class="mcp-tab ${s.id === mcpTab ? 'on' : ''}" data-mcp-tab="${s.id}">
            <strong>${s.name}</strong>
            <span class="dom">${s.domain || ''}</span>
            <em>${n} tool${n === 1 ? '' : 's'} selected</em>
          </button>`;
        }).join('')}
      </div>
      <div class="mcp-tools">
        <div class="mcp-tools-head">
          <div>
            <strong>${active.name}</strong>
            <p class="sub" style="margin:4px 0 0">${active.description}</p>
          </div>
          <div class="btns">
            <button type="button" class="btn" data-all="${active.id}">Select all</button>
            <button type="button" class="btn" data-none="${active.id}">Clear</button>
          </div>
        </div>
        <div class="tool-list">
          ${active.tools.map(t => {
            const id = toolId(t);
            const on = picked.has(id);
            return `<label class="tool-row">
              <input type="checkbox" data-tool="${active.id}:${id}" ${on ? 'checked' : ''}>
              <span class="tn">${id}</span>
              <span class="td">${toolDesc(t)}</span>
            </label>`;
          }).join('')}
        </div>
      </div>
    </div>`;
}

function onMcpClick(e) {
  const tab = e.target.closest('[data-mcp-tab]');
  if (tab) {
    mcpTab = tab.dataset.mcpTab;
    paintMcp();
    return;
  }
  const all = e.target.closest('[data-all]');
  const none = e.target.closest('[data-none]');
  const sid = (all || none)?.dataset.all || (all || none)?.dataset.none;
  if (sid) {
    const server = catalog.mcp.find(m => m.id === sid);
    const set = pickedFor(sid);
    set.clear();
    if (all && server) server.tools.forEach(t => set.add(toolId(t)));
    paintMcp();
    return;
  }
  const box = e.target.closest('input[data-tool]');
  if (box) {
    const [id, tid] = box.dataset.tool.split(':');
    const set = pickedFor(id);
    if (box.checked) set.add(tid); else set.delete(tid);
    paintMcp();
  }
}

function applyDemo() {
  document.getElementById('description').value = DEMO.description;
  document.getElementById('prompt').value = DEMO.prompt;
  selectSkill(DEMO.skills[0] || '');
  mcpPicked = {};
  (catalog.mcp || []).forEach(m => { mcpPicked[m.id] = new Set(); });
  const want = new Set(DEMO.githubTools);
  (catalog.mcp.find(m => m.id === 'github')?.tools || []).forEach(t => {
    const id = toolId(t);
    if (want.has(id)) pickedFor('github').add(id);
  });
  mcpTab = 'github';
  paintMcp();
}

function skillSlug(title) {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);
}

function paintSkillTarget() {
  const sid = skillSlug(document.getElementById('skill-title').value.trim());
  document.getElementById('skill-target').textContent = sid
    ? `Writes vision-demo-2026/demo-scripts/agentregistry/skill/${sid}/, commits it and pushes to main.`
    : '';
}

function openSkillModal() {
  ['skill-title', 'skill-desc', 'skill-body'].forEach(id => { document.getElementById(id).value = ''; });
  document.getElementById('skill-msg').textContent = '';
  paintSkillTarget();
  document.getElementById('skill-modal').style.display = 'flex';
  document.getElementById('skill-title').focus();
}

function closeSkillModal() {
  document.getElementById('skill-modal').style.display = 'none';
}

async function saveSkill() {
  const msg = document.getElementById('skill-msg');
  const btn = document.getElementById('skill-save');
  const body = {
    title: document.getElementById('skill-title').value.trim(),
    description: document.getElementById('skill-desc').value.trim(),
    body: document.getElementById('skill-body').value,
  };
  btn.disabled = true;
  msg.textContent = 'Writing the package, committing and pushing…';
  let r;
  try {
    r = await fetch('/api/agents/skills', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(x => x.json());
  } catch (e) {
    btn.disabled = false;
    msg.textContent = 'The console could not reach the server.';
    return;
  }
  btn.disabled = false;
  if (!r.ok) { msg.textContent = r.error || 'Could not create the skill.'; return; }

  catalog = await fetch('/api/agents/catalog').then(x => x.json());
  paintSkills();
  selectSkill(r.id);
  closeSkillModal();

  const parts = [];
  parts.push(r.commit ? `Committed ${r.commit}` : 'Not committed');
  parts.push(r.pushed ? 'pushed to main' : 'not pushed');
  parts.push(r.registered ? `registered as ${r.id}` : 'not registered');
  const detail = r.detail ? ` ${r.detail}` : '';
  document.getElementById('form-msg').textContent =
    `${parts.join(', ')}. Usable here now; the body reaches the public mirror when the `
    + `mirror action has run.${detail}`;
}

function specFromForm() {
  const chosen = pickedSkill();
  const skills = chosen ? [chosen] : [];
  const mcp = [];
  for (const m of catalog.mcp) {
    const tools = [...pickedFor(m.id)];
    if (tools.length) mcp.push({ id: m.id, tools });
  }
  return {
    name: document.getElementById('name').value.trim(),
    description: document.getElementById('description').value.trim(),
    prompt: document.getElementById('prompt').value.trim(),
    skills, mcp,
  };
}

function showHome() {
  document.getElementById('home-view').style.display = '';
  document.getElementById('wizard-view').style.display = 'none';
  editing = false;
}

function showWizard() {
  document.getElementById('home-view').style.display = 'none';
  document.getElementById('wizard-view').style.display = '';
  goStep(1);
}

function goStep(n) {
  if (n === 2 || n === 3 || n === 4) {
    const name = document.getElementById('name').value.trim();
    if (!name) {
      document.getElementById('form-msg').textContent = 'Give it a name first.';
      n = 1;
    }
  }
  wizStep = n;
  document.querySelectorAll('.wiz-step').forEach(el => {
    el.classList.toggle('on', el.dataset.step === String(n));
  });
  document.querySelectorAll('#wiz-nav li').forEach(el => {
    const g = parseInt(el.dataset.goto, 10);
    el.classList.toggle('on', g === n);
    el.classList.toggle('done', g < n);
  });
  document.getElementById('wiz-back').style.display = n === 1 ? 'none' : '';
  document.getElementById('wiz-next').style.display = n === 4 ? 'none' : '';
  document.getElementById('deploy').style.display = n === 4 ? '' : 'none';
  if (n === 4) paintReview();
  if (n !== 1) document.getElementById('form-msg').textContent = '';
}

function wizNext() { goStep(Math.min(4, wizStep + 1)); }
function wizBack() { goStep(Math.max(1, wizStep - 1)); }

function paintReview() {
  const spec = specFromForm();
  const skillTitles = (spec.skills || []).map(id => {
    const s = catalog.skills.find(x => x.id === id);
    return s ? s.title : id;
  });
  const mcpLines = (spec.mcp || []).map(m => {
    const server = catalog.mcp.find(x => x.id === m.id);
    return (server ? server.name : m.id) + ' · ' + m.tools.length + ' tool' + (m.tools.length === 1 ? '' : 's');
  });
  document.getElementById('review').innerHTML = `
    <div><dt>Name</dt><dd>${spec.name || '—'}</dd></div>
    <div><dt>For</dt><dd>${spec.description || '—'}</dd></div>
    <div><dt>Skills</dt><dd>${skillTitles.join(', ') || 'none'}</dd></div>
    <div><dt>MCP</dt><dd>${mcpLines.join('; ') || 'none'}</dd></div>
    <div><dt>Version</dt><dd>${editing ? 'new version of ' + spec.name : 'v1 on first deploy'}</dd></div>`;
}

function startNew() {
  selected = null;
  editing = false;
  document.getElementById('name').readOnly = false;
  document.getElementById('name').value = '';
  document.getElementById('form-title').textContent = 'New agent';
  document.getElementById('deploy').textContent = 'Create and deploy';
  applyDemo();
  document.getElementById('form-msg').textContent = '';
  showWizard();
}

function loadIntoForm(name) {
  const a = agents.find(x => x.name === name);
  if (!a) return;
  editing = true;
  document.getElementById('form-title').textContent = 'Edit ' + a.name;
  document.getElementById('deploy').textContent = 'Publish new version';
  const nameEl = document.getElementById('name');
  nameEl.value = a.name;
  nameEl.readOnly = true;
  document.getElementById('description').value = a.description || '';
  document.getElementById('prompt').value = a.prompt || '';
  selectSkill((a.skills || [])[0] || '');
  mcpPicked = {};
  (catalog.mcp || []).forEach(m => { mcpPicked[m.id] = new Set(); });
  for (const m of a.mcp || []) {
    mcpPicked[m.id] = new Set(m.tools || []);
  }
  mcpTab = (a.mcp && a.mcp[0] && a.mcp[0].id) || mcpTab || 'github';
  paintMcp();
  document.getElementById('form-msg').textContent = a.version
    ? ('Editing ' + a.name + ' · current ' + a.version)
    : ('Editing ' + a.name);
  showWizard();
}

async function deploy() {
  const msg = document.getElementById('form-msg');
  const editing = document.getElementById('name').readOnly;
  msg.textContent = editing ? 'Publishing new version…' : 'Creating…';
  const r = await fetch('/api/agents', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(specFromForm()),
  }).then(x => x.json());
  if (!r.ok) { msg.textContent = r.error || 'failed'; return; }
  const ver = r.agent.version ? (' · ' + r.agent.version) : '';
  msg.textContent = r.agent.applied
    ? ('Published to AgentRegistry and deployed onto kagent' + ver + '.')
    : ('Saved. Registry: ' + (r.agent.apply_error || 'not deployed'));
  await refreshList();
  showHome();
  show(r.agent.name);
}

async function refreshList() {
  const r = await fetch('/api/agents').then(x => x.json());
  agents = r.agents || [];
  const cards = agents.filter(a => a.name !== selected);
  document.getElementById('list').innerHTML = agents.length
    ? (cards.length ? cards.map(a => {
        const needsMcp = (a.mcp || []).some(m => (m.tools || []).length);
        let pill = a.applied
          ? '<span class="pill ok">Deployed</span>'
          : '<span class="pill wait">Not deployed</span>';
        if (needsMcp && a.applied) {
          pill += mcpApproved(a)
            ? '<span class="pill ok">MCP approved</span>'
            : '<span class="pill wait">Awaiting security</span>';
        }
        return `<div class="agent-card ${selected === a.name ? 'active' : ''}" data-name="${a.name}">
        <h3>${a.name}</h3>
        <p class="sub">${a.version ? a.version + ' · ' : ''}${a.description || ''}</p>
        <div>${pill}</div>
        <div class="card-actions">
          <button type="button" class="btn" data-open="${a.name}">Open</button>
          <button type="button" class="btn" data-edit="${a.name}">Edit</button>
          <button type="button" class="btn" data-del="${a.name}">Delete</button>
        </div>
      </div>`;
      }).join('') : '')
    : '<p class="sub">None yet. New agent starts the wizard.</p>';
  document.getElementById('list').onclick = e => {
    const del = e.target.closest('[data-del]');
    const edit = e.target.closest('[data-edit]');
    const open = e.target.closest('[data-open]');
    const card = e.target.closest('[data-name]');
    if (del) { e.stopPropagation(); remove(del.dataset.del); return; }
    if (edit) { e.stopPropagation(); loadIntoForm(edit.dataset.edit); return; }
    const name = (open && open.dataset.open) || (card && card.dataset.name);
    if (name) show(name);
  };
}

let poll = null;

function closeDetail() {
  selected = null;
  document.getElementById('detail').style.display = 'none';
  if (poll) clearInterval(poll);
  refreshList();
}

function show(name) {
  const a = agents.find(x => x.name === name);
  selected = name;
  const box = document.getElementById('detail');
  if (!a) { box.style.display = 'none'; if (poll) clearInterval(poll); return; }
  showHome();
  refreshList();
  box.style.display = 'block';
  document.getElementById('detail-name').textContent = a.version ? (a.name + ' · ' + a.version) : a.name;
  document.getElementById('yaml-view').textContent = a.yaml || '';
  const pol = document.getElementById('policy-details');
  const polView = document.getElementById('policy-view');
  if (mcpApproved(a) && a.policy_yaml) {
    pol.style.display = '';
    polView.textContent = a.policy_yaml;
  } else {
    pol.style.display = 'none';
    polView.textContent = '';
  }
  paintApproval(a);
  pollStatus(name);
  if (poll) clearInterval(poll);
  poll = setInterval(() => pollStatus(name), 3000);
}

function mcpApproved(a) {
  return !!(a && (a.mcp_approved || a.github_approved));
}

function mcpGroups(a) {
  return (a.mcp || []).filter(m => (m.tools || []).length).map(m => {
    const server = catalog.mcp.find(x => x.id === m.id);
    return { id: m.id, name: server ? server.name : m.id, tools: m.tools };
  });
}

function mcpToolCount(a) {
  return mcpGroups(a).reduce((n, g) => n + g.tools.length, 0);
}

function paintApproval(a) {
  const need = mcpGroups(a).length > 0;
  const pending = document.getElementById('approve-card');
  const done = document.getElementById('approved-card');
  if (!need || !a.applied) {
    pending.style.display = 'none';
    done.style.display = 'none';
    return;
  }
  const n = mcpToolCount(a);
  if (mcpApproved(a)) {
    pending.style.display = 'none';
    done.style.display = 'block';
    document.getElementById('approved-detail').textContent =
      'ServiceAccount ' + a.name + ' may call ' + n + ' MCP tool' + (n === 1 ? '' : 's') + '.';
    return;
  }
  done.style.display = 'none';
  pending.style.display = 'block';
  const probe = a.github_probe;
  const note = document.getElementById('approve-msg');
  if (probe && probe.allowed === false) {
    note.textContent = 'Denied. Probe from the agent pod: ' + (probe.detail || 'denied');
  } else {
    note.textContent = n + ' tool' + (n === 1 ? '' : 's') + ' requested.';
  }
}



async function pollStatus(name) {
  const st = await fetch('/api/agents/' + encodeURIComponent(name) + '/status').then(r => r.json());
  document.getElementById('life').innerHTML = (st.steps || []).map(s =>
    `<li class="${s.state}"><strong>${s.label}</strong><span>${s.detail || ''}</span></li>`
  ).join('');
  if (st.agent) {
    const i = agents.findIndex(x => x.name === name);
    if (i >= 0) {
      agents[i] = { ...agents[i], ...st.agent };
      paintApproval(agents[i]);
    } else {
      paintApproval(st.agent);
    }
  }
  const a = agents.find(x => x.name === name) || st.agent || {};
  const needsMcp = mcpGroups(a).length > 0;
  const chat = document.getElementById('open-chat');
  const canChat = st.ready && st.urls && st.urls.prompt && (!needsMcp || mcpApproved(a));
  if (canChat) {
    chat.href = st.urls.prompt;
    chat.style.display = 'inline-block';
  } else {
    chat.style.display = 'none';
  }
  const log = document.getElementById('life-log');
  if (st.logs) log.textContent = st.logs;
  const line = document.getElementById('detail-status');
  if (line) {
    if (needsMcp && a.applied && !mcpApproved(a)) {
      line.textContent = 'Deployed. Waiting for a platform admin to allow MCP tools.';
    } else {
      line.textContent = st.ready ? 'Green. Prompt it in kagent.' : (st.steps || []).map(s => s.label + ': ' + s.state).join(' · ');
    }
  }
}



async function remove(name) {
  const who = name || selected;
  if (!who) return;
  if (!confirm('Delete ' + who + ' from AgentRegistry and kagent?')) return;
  await fetch('/api/agents/' + encodeURIComponent(who), { method: 'DELETE' });
  if (selected === who) {
    selected = null;
    document.getElementById('detail').style.display = 'none';
    if (poll) clearInterval(poll);
  }
  showHome();
  await refreshList();
}

boot();
