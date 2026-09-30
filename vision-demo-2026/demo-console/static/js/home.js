// Home page: filter the labs, then fill in what is actually running. Every number here is
// read from the console's own APIs; nothing is a placeholder dressed up as live.
(() => {
  const grid = document.getElementById('catalogue');
  const filters = document.getElementById('cat-filter');
  if (!grid || !filters) return;
  const labs = [...grid.querySelectorAll('.st-lab')];

  filters.querySelectorAll('button').forEach(b => {
    const f = b.dataset.filter;
    b.querySelector('b').textContent = labs.filter(c => f === 'all' || c.dataset.domain === f).length;
  });
  function filter(value) {
    filters.querySelectorAll('button').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.filter === value)));
    labs.forEach(c => { c.hidden = value !== 'all' && c.dataset.domain !== value; });
    localStorage.setItem('catalogue-filter', value);
  }
  filters.addEventListener('click', e => { const b = e.target.closest('button'); if (b) filter(b.dataset.filter); });
  filter(localStorage.getItem('catalogue-filter') || 'all');

  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const clusters = new Map();
  function paintClusters() {
    const box = document.getElementById('live-clusters');
    const rows = [...clusters.values()].sort((a, b) => (b.ready - a.ready) || a.name.localeCompare(b.name));
    box.innerHTML = rows.map(c => `<span class="st-pill ${c.ready ? 'up' : 'down'}">${esc(c.name)}</span>`).join('')
      || '<span class="st-pill down">none reachable</span>';
  }

  // One status call per lab. The server caches readiness per cluster, so this is cheap.
  labs.forEach(tile => {
    const pill = tile.querySelector('[data-ready]');
    fetch('/api/labs/status/' + encodeURIComponent(tile.dataset.lab)).then(r => r.json()).then(st => {
      (st.clusters || []).forEach(c => clusters.set(c.name, c));
      paintClusters();
      const names = (st.clusters || []).map(c => c.name).join(' + ');
      pill.className = 'st-pill ' + (st.ready ? 'up' : 'down');
      pill.textContent = st.ready ? `${names} ready` : `${names} not up`;
    }).catch(() => { pill.className = 'st-pill down'; pill.textContent = 'status unknown'; });
  });

  fetch('/api/agents').then(r => r.json()).then(d => {
    const live = (d.agents || []).filter(a => a.applied).length;
    document.getElementById('live-agents').textContent = live;
  }).catch(() => { document.getElementById('live-agents').textContent = '–'; });

  fetch('/api/agents/catalog').then(r => r.json()).then(d => {
    const mcp = d.mcp || [];
    document.getElementById('live-mcp').textContent = mcp.length;
    const auto = mcp.filter(m => m.autoApprove).length;
    document.getElementById('live-mcp-sub').textContent =
      `MCP servers in AgentRegistry · ${auto} ready to use without approval`;
  }).catch(() => { document.getElementById('live-mcp').textContent = '–'; });
})();
