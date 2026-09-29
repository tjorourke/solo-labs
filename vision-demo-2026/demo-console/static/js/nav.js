// Area menus in the top bar: one open at a time, closed by a click elsewhere or Escape.
(() => {
  const menus = [...document.querySelectorAll('.console-nav .nav-menu')];
  menus.forEach(m => m.addEventListener('toggle', () => {
    if (m.open) menus.forEach(o => { if (o !== m) o.open = false; });
  }));
  document.addEventListener('click', e => {
    if (!e.target.closest('.nav-menu')) menus.forEach(m => { m.open = false; });
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') menus.forEach(m => { m.open = false; });
  });
})();
