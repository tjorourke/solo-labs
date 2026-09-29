// The cluster dot in the nav. Shared by every generated page.
(function () {
  const dot = document.getElementById('dot');
  const label = document.getElementById('status-label');
  if (!dot || !label) return;
  const lab = location.pathname.split('/')[1];
  if (/^demo-\d+$/.test(lab)) {
    label.textContent = 'checking lab clusters';
    fetch('/api/labs/status/' + lab).then(r => {
      if (!r.ok) throw new Error('Cluster status unavailable');
      return r.json();
    }).then(s => {
      dot.className = 'dot ' + (s.ready ? 'live' : 'off');
      label.textContent = (s.ready ? 'live · ' : 'unavailable · ') + s.clusters.map(c => c.name).join(' + ');
      label.title = s.clusters.map(c => c.context + ': API ' + (c.ready ? 'reachable' : 'unreachable')).join('; ');
    }).catch(() => { dot.className = 'dot off'; label.textContent = 'lab status unavailable'; });
    return;
  }
  label.title = 'Model-routing traffic feed';
  fetch('/api/status').then(r => r.json()).then(s => {
    if (s.decisions) {
      dot.className = 'dot live';
      label.textContent = s.context ? ('live · ' + s.context.split('/').pop()) : 'live';
    } else {
      dot.className = 'dot off';
      label.textContent = s.error || 'cluster not attached';
    }
  }).catch(() => {
    dot.className = 'dot off';
    label.textContent = 'console only';
  });
})();
