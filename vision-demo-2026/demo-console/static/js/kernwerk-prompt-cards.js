// The prompt cards, shared by the Demo prompts page and the Data protection page.
// One card per prompt: what it is, where it goes, the prompt itself and a copy button.
// Deliberately free of explanation. The presenter is talking over this, so the card
// carries what they need to point at and nothing they would have to read.
const kpEsc = s => String(s == null ? '' : s).replace(/[<>&]/g, m => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[m]));

const KP_LANES = {
  public:  {cls: 'Class 1', name: 'nothing restricted',  pill: 'lane-anywhere'},
  eu:      {cls: 'Class 2', name: 'must stay in the EU',   pill: 'lane-eu'},
  private: {cls: 'Class 3', name: 'never leaves Kernwerk', pill: 'lane-private'},
  stop:    {cls: 'Stopped', name: 'no model is called',  pill: 'frontier'},
};

// What in the prompt decides its class, so it can be pointed at rather than described.
const KP_MARKERS = [
  /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/gi,
  /\bKW-\d{6}\b/g,
  /\bDE\d{2}(?: ?\d{4}){3,}(?: ?\d{1,4})?/g,
  /KERNWERK RESTRICTED|STRENG VERTRAULICH/gi,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\b(?:personnel|personal data|personenbezogene?n?|Personalakte)\b/gi,
  /\+49[\d ]{6,}/g,
  /\b[A-ZÄÖÜ][a-zäöüß]+(?:strasse|straße|str\.)\s\d+/g,
];

function kpHighlight(text) {
  const spans = [];
  for (const re of KP_MARKERS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m[0].length === 0) { re.lastIndex++; continue; }
      spans.push([m.index, m.index + m[0].length]);
    }
  }
  if (!spans.length) return kpEsc(text);
  spans.sort((a, b) => a[0] - b[0]);
  let out = '', pos = 0;
  for (const [a, b] of spans) {
    if (a < pos) continue;
    out += kpEsc(text.slice(pos, a)) + '<mark>' + kpEsc(text.slice(a, b)) + '</mark>';
    pos = b;
  }
  return out + kpEsc(text.slice(pos));
}

// The same three marks the decision cards use: a globe for what may leave, a shield for
// what may leave but not the region, a padlock for what stays, and a cross for refused.
const KP_ICON = {
  public:  '<svg viewBox="0 0 16 16" class="li"><circle cx="8" cy="8" r="6.2"/><path d="M1.8 8h12.4M8 1.8c1.8 2 1.8 10.4 0 12.4M8 1.8c-1.8 2-1.8 10.4 0 12.4"/></svg>',
  eu:      '<svg viewBox="0 0 16 16" class="li"><path d="M8 1.6 2.6 3.8v4c0 3 2.3 5.4 5.4 6.6 3.1-1.2 5.4-3.6 5.4-6.6v-4z"/><circle cx="8" cy="7.8" r="2.3"/></svg>',
  private: '<svg viewBox="0 0 16 16" class="li"><rect x="3.2" y="7" width="9.6" height="7" rx="1.6"/><path d="M5.5 7V5.1a2.5 2.5 0 0 1 5 0V7"/></svg>',
  stop:    '<svg viewBox="0 0 16 16" class="li"><circle cx="8" cy="8" r="6.2"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5"/></svg>',
};

function kpCard(p) {
  const L = KP_LANES[p.cls] || KP_LANES.public;
  const redacts = (p.redacts || []).length
    ? '<div class="kp-redacts">' + p.redacts.map(r => `<span class="pill">{${kpEsc(r)}}</span>`).join('') + '</div>'
    : '';
  const file = p.href
    ? `<div class="kp-file"><a href="${kpEsc(p.href)}" download>Download the file</a>, then attach it to the prompt</div>`
    : '';
  return `<div class="kp-card lane-${kpEsc(p.cls)}">
    <div class="kp-what">
      <div class="kp-label">${kpEsc(p.label)}</div>
      <span class="pill kp-lane ${L.pill}">${KP_ICON[p.cls] || ''}${L.cls} · ${L.name}</span>
      <div class="kp-where">${kpEsc(p.where)}<br><b>${kpEsc(p.expected)}</b></div>
      ${redacts}
    </div>
    <div><div class="kp-text">${kpHighlight(p.text)}</div>${file}</div>
    <button class="btn kp-copy" data-key="${kpEsc(p.key)}">Copy</button>
  </div>`;
}

/** Render every group for one page into a container, and wire the copy buttons. */
async function kpRender(containerId, page, showTitles = true) {
  const data = await fetch('/api/kernwerk/prompts').then(r => r.json());
  const groups = data.groups.filter(g => g.page === page);
  const byKey = new Map();
  for (const g of groups) for (const p of g.prompts) byKey.set(p.key, p);
  document.getElementById(containerId).innerHTML = groups.map(g => `<section class="kp-group">
    ${showTitles ? `<h2>${kpEsc(g.title)}</h2>` : ''}
    ${g.prompts.map(kpCard).join('')}
  </section>`).join('');
  document.querySelectorAll('#' + containerId + ' .kp-copy').forEach(b => {
    b.onclick = async () => {
      await navigator.clipboard.writeText(byKey.get(b.dataset.key).text);
      b.textContent = 'Copied';
      b.classList.add('done');
      setTimeout(() => { b.textContent = 'Copy'; b.classList.remove('done'); }, 1600);
    };
  });
  return groups;
}

/** The manifests, one collapsed block per file. Read from the applied files, so a page
 *  cannot claim something the cluster is not running. */
async function kpManifests(containerId) {
  const d = await fetch('/api/kernwerk/manifests').then(r => r.json());
  const host = document.getElementById(containerId);
  if (!host || !d.files || !d.files.length) return;
  host.innerHTML = d.files.map(f => `<details class="kp-config">
    <summary>${kpEsc(f.name)}</summary>
    <p class="kp-mhint">${kpEsc(f.hint)}</p>
    <pre>${f.text.split('\n').map(line => /^\s*(#|\/\/)/.test(line)
      ? `<span class="kp-code-comment">${kpEsc(line)}</span>` : kpEsc(line)).join('\n')}</pre>
  </details>`).join('');
}
