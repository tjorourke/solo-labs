// Catalogue: filter the cards by area and switch between cards and a list.
// Both choices are remembered, so the page opens the way it was left.
(() => {
  const grid = document.getElementById('catalogue');
  const filters = document.getElementById('cat-filter');
  const views = document.getElementById('cat-view');
  if (!grid || !filters || !views) return;
  const cards = [...grid.querySelectorAll('.feature-card')];

  filters.querySelectorAll('button').forEach(b => {
    const f = b.dataset.filter;
    b.querySelector('b').textContent = cards.filter(c => f === 'all' || c.dataset.domain === f).length;
  });

  function press(group, attr, value) {
    group.querySelectorAll('button').forEach(b => b.setAttribute('aria-pressed', String(b.dataset[attr] === value)));
  }

  function filter(value) {
    press(filters, 'filter', value);
    cards.forEach(c => { c.hidden = value !== 'all' && c.dataset.domain !== value; });
    localStorage.setItem('catalogue-filter', value);
  }

  function view(value) {
    press(views, 'view', value);
    grid.classList.toggle('list', value === 'list');
    localStorage.setItem('catalogue-view', value);
  }

  filters.addEventListener('click', e => { const b = e.target.closest('button'); if (b) filter(b.dataset.filter); });
  views.addEventListener('click', e => { const b = e.target.closest('button'); if (b) view(b.dataset.view); });
  filter(localStorage.getItem('catalogue-filter') || 'all');
  view(localStorage.getItem('catalogue-view') || 'cards');
})();
