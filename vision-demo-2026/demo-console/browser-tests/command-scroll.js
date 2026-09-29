// Run with browse eval on a chapter containing a long command, at desktop size.
// Selects a step and its Commands tab only. Never runs a command or resets a lab.
(() => {
  const scripts = [...document.querySelectorAll('.pr-script')];
  const longest = scripts.reduce((a, b) => a.textContent.length > b.textContent.length ? a : b);
  document.querySelectorAll('.pr-cmd-head')[Number(longest.dataset.script)].click();
  document.querySelector('[data-tab="script"]').click();
  const pane = document.querySelector('[data-pane="script"]');
  const end = [...longest.querySelectorAll('pre')].at(-1);
  pane.scrollTop = pane.scrollHeight;
  const limit = document.querySelector('.term-dock')?.getBoundingClientRect().top ?? innerHeight;
  const bottom = end.getBoundingClientRect().bottom;
  if (pane.clientHeight >= pane.scrollHeight || pane.scrollTop <= 0)
    throw new Error('The long command panel has no vertical scroll range');
  if (bottom > limit || bottom < pane.getBoundingClientRect().top)
    throw new Error(`Final code line is clipped: bottom=${bottom}, visible limit=${limit}`);
  const wide = [...longest.querySelectorAll('pre')].find(p => p.scrollWidth > p.clientWidth);
  if (wide) {
    wide.scrollLeft = wide.scrollWidth;
    if (wide.scrollLeft <= 0) throw new Error('Wide code cannot scroll horizontally');
  }
  return {passed: true, scrollTop: pane.scrollTop, codeBottom: bottom, visibleLimit: limit,
          finalLine: end.textContent.trim().split('\n').at(-1)};
})();
