// Shared by the Data protection page and Kernwerk's decisions page: one
// decision, as the gateway logs record it, drawn as three columns and a verdict.
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));

const LABELS = {
  NAME: 'Name', EMAIL: 'Email', PHONE: 'Phone', ADDRESS: 'Address', AGE: 'Age',
  IBAN: 'IBAN', CARD: 'Card number', GERMAN_TAX_ID: 'Tax ID',
  KERNWERK_EMPLOYEE_ID: 'Personnel number',
};
const LANES = {
  public: {cls: 'Class 1', name: 'Can go anywhere', where: 'An external model, such as Claude', short: 'External model', pill: 'lane-anywhere'},
  eu: {cls: 'Class 2', name: 'Must stay in the EU', where: 'A model hosted in EU regions only', short: 'EU-hosted model', pill: 'lane-eu'},
  private: {cls: 'Class 3', name: 'Never leaves Kernwerk', where: "Kernwerk's own model, in Kernwerk's private datacenter", short: "Kernwerk's private datacenter", pill: 'lane-private'},
};
const label = k => LABELS[k] || k.toLowerCase().replace(/_/g, ' ');
const PH = /\{([A-Z_]+)\}/g;

// Line the masked text up against the original. The DLP service keeps every
// character it does not replace, so the text between two placeholders is
// found verbatim in the original and whatever sits between is what it removed.
function removals(original, masked) {
  const parts = masked.split(PH);            // literal, key, literal, key, ...
  const found = [];
  let pos = original.indexOf(parts[0]);
  if (pos < 0) return found;
  pos += parts[0].length;
  for (let i = 1; i < parts.length; i += 2) {
    const next = parts[i + 1];
    const end = next === '' ? (i + 2 < parts.length ? pos : original.length) : original.indexOf(next, pos);
    if (end < 0) break;
    found.push({key: parts[i], value: original.slice(pos, end), start: pos, end});
    pos = end + next.length;
  }
  return found;
}

function markOriginal(original, found) {
  let out = '', pos = 0;
  for (const f of found) {
    out += esc(original.slice(pos, f.start));
    out += `<mark class="pii" title="${esc(label(f.key))}">${esc(f.value)}</mark>`;
    pos = f.end;
  }
  return out + esc(original.slice(pos));
}

const markMasked = masked => esc(masked).replace(PH, (_, k) => `<span class="ph">${esc(label(k))}</span>`);

function md(text) {
  const lines = esc(text).split('\n');
  let out = '', list = false;
  for (let line of lines) {
    line = line.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
               .replace(PH, (_, k) => `<span class="ph">${esc(label(k))}</span>`);
    const li = line.match(/^\s*(?:[-*]|\d+\.)\s+(.*)/);
    if (li) {
      if (!list) { out += '<ul>'; list = true; }
      out += `<li>${li[1]}</li>`;
      continue;
    }
    if (list) { out += '</ul>'; list = false; }
    out += line.trim() ? `<p>${line}</p>` : '';
  }
  return out + (list ? '</ul>' : '');
}

function chips(found) {
  const counts = {};
  for (const f of found) counts[label(f.key)] = (counts[label(f.key)] || 0) + 1;
  return Object.entries(counts).map(([k, n]) => `<span class="ph">${esc(k)}${n > 1 ? ' × ' + n : ''}</span>`).join(' ');
}

// A PDF arrives as "[name, N page(s)]" and its text; show the name as a pill.
function splitFiles(prompt, files) {
  let body = prompt;
  const pills = (files || []).map(f => {
    body = body.replace(`[${f.name}, ${f.pages} page(s)]\n`, '');
    return `<span class="pill">${esc(f.name)} · ${f.pages} page${f.pages === 1 ? '' : 's'}</span>`;
  });
  return {body, pills: pills.length ? `<div class="dlp-files">${pills.join(' ')}</div>` : ''};
}

const stamp = ts => new Date(ts * 1000).toLocaleTimeString('en-GB', {hour: '2-digit', minute: '2-digit', second: '2-digit'});

function state(d) {
  if (d.status === 403 || d.answered === 403) return 'stopped';
  if (d.status && d.status !== 200) return 'failed';
  if (d.answer === null || d.answer === undefined) return 'waiting';
  return 'done';
}

function column(n, title, where, cls, body) {
  return `<section class="dlp-col ${cls}"><h3><span class="n">${n}</span> ${title}</h3>
    ${where ? `<div class="dlp-where">${where}</div>` : ''}<div class="dlp-body">${body}</div></section>`;
}

// Returns {lane, flow, verdict} HTML for one decision.
function renderDecision(d) {
  const st = state(d);
  const found = d.masked ? removals(d.prompt, d.masked) : [];
  const sent = splitFiles(markOriginal(d.prompt, found), d.files);
  const col1 = column(1, 'What the employee sent', 'In Claude Desktop', 'done',
    `${sent.pills}<pre class="dlp-text">${sent.body}</pre>`);
  const L = LANES[d.lane];

  if (st === 'stopped') {
    const stop = `<div class="dlp-stop"><strong>Stopped at the gateway</strong><p>It carries a secret or tries to override the model's rules.</p></div>`;
    return {
      lane: null,
      flow: col1 + column(2, 'What the model received', '', 'stopped', stop)
        + column(3, 'What came back', '', 'stopped', '<p class="dlp-empty">No model was called.</p>'),
      verdict: `<div class="dlp-verdict show stop"><strong>Stopped at the gateway.</strong>
        <p>No model received this, not even Kernwerk's own. Claude Desktop was told why, and no application had to change.</p></div>`,
    };
  }
  const got = d.masked === null ? null : splitFiles(markMasked(d.masked), d.files);
  const masked = got ? `${got.pills}<pre class="dlp-text">${got.body}</pre>` : '<p class="dlp-empty">At the gateway…</p>';
  const col2 = column(2, 'What the model received', "After Kernwerk's DLP service, in Kernwerk's cluster",
    d.masked === null ? 'working' : 'done', masked);
  let col3;
  if (st === 'failed') col3 = column(3, 'What came back', L ? L.where : '', 'stopped',
    `<div class="dlp-stop"><strong>The model did not answer</strong><p>${esc(d.reason || 'Status ' + d.status)}</p></div>`);
  else if (st === 'waiting') col3 = column(3, 'What came back', L ? L.where : 'The model the gateway picked', 'working',
    '<p class="dlp-empty">Waiting for the model…</p>');
  else col3 = column(3, 'What came back', L ? L.where : '', 'done', `<div class="dlp-answer">${md(d.answer)}</div>`);

  let verdict = '';
  if (st === 'done' && L) {
    const route = {
      public: 'Nothing restricted and nothing that must stay in the EU, so it was free to use an external model.',
      eu: 'It carries personal data, so the gateway sent it to a model hosted in EU regions only.',
      private: "It is marked restricted, so the gateway kept it on Kernwerk's own model. It did not leave Kernwerk's datacenter, not even to be checked.",
    }[d.lane];
    let dlpLine = '<p>No personal data in it, so the DLP service changed nothing.</p>';
    let removed = '';
    if (found.length) {
      const rows = found.map(f => `<tr><td>${esc(label(f.key))}</td><td><mark class="pii">${esc(f.value)}</mark></td></tr>`).join('');
      dlpLine = `<p>Kernwerk's DLP service replaced ${found.length} ${found.length === 1 ? 'piece' : 'pieces'} of personal data before the model saw it: ${chips(found)}</p>`;
      removed = `<details class="dlp-removed"><summary>What was replaced</summary><table class="plain"><tbody>${rows}</tbody></table></details>`;
    }
    const back = d.answer_original ? removals(d.answer_original, d.answer) : [];
    if (back.length) {
      const rows = back.map(f => `<tr><td>${esc(label(f.key))}</td><td><mark class="pii">${esc(f.value)}</mark></td></tr>`).join('');
      dlpLine += `<p>The answer carried personal data too, and the DLP service replaced it before Claude Desktop showed it: ${chips(back)}</p>`;
      removed += `<details class="dlp-removed"><summary>What was replaced in the answer</summary><table class="plain"><tbody>${rows}</tbody></table></details>`;
    }
    verdict = `<div class="dlp-verdict show pass lane-${d.lane}">
      <div class="dlp-verdict-head"><strong>${L.cls} · ${L.name}.</strong></div>
      <p>${route}</p>${dlpLine}${removed}</div>`;
  }
  return {lane: d.lane, flow: col1 + col2 + col3, verdict};
}

// The short form, for someone who wants the outcome and not the text: where
// it went, and what personal data never reached a model.
function swaps(found) {
  const seen = new Map();
  for (const f of found) {
    const k = f.value.trim() + '|' + f.key;
    if (f.value.trim() && !seen.has(k)) seen.set(k, f);
  }
  const all = [...seen.values()];
  const shown = all.slice(0, 8).map(f =>
    `<span class="dlp-swap"><s>${esc(f.value.trim())}</s> → <span class="ph">${esc(label(f.key))}</span></span>`);
  if (all.length > 8) shown.push(`<span class="dlp-swap more">and ${all.length - 8} more</span>`);
  return shown.join('');
}

function renderSummary(d) {
  const st = state(d);
  const L = LANES[d.lane];
  const found = d.masked ? removals(d.prompt, d.masked) : [];
  const back = d.answer_original && d.answer ? removals(d.answer_original, d.answer) : [];
  const files = (d.files || []).map(f => `<span class="pill">${esc(f.name)}</span>`).join(' ');
  if (st === 'stopped') return {cls: 'stop', html: `
    <div class="dlp-result-head"><strong>Stopped</strong>${files}</div>
    <p>It carried a secret or tried to override the model's rules. No model received it, not even Kernwerk's own.</p>`};
  if (st === 'failed') return {cls: 'stop', html: `
    <div class="dlp-result-head"><strong>The model did not answer</strong></div><p>${esc(d.reason || 'Status ' + d.status)}</p>`};
  if (!L) return {cls: 'waiting', html: `<div class="dlp-result-head"><strong>At the gateway…</strong>${files}</div>`};
  const why = {
    public: 'Nothing restricted and no personal data, so it was free to use an external model.',
    eu: 'It carries personal data, so it went to a model hosted in the EU only.',
    private: "It is marked restricted, so it stayed on Kernwerk's own model and never left its datacenter.",
  }[d.lane];
  let html = `<div class="dlp-result-head"><strong>${L.cls} · ${L.name}</strong>${files}</div><p>${why}</p>`;
  if (found.length) html += `<p class="dlp-result-sub">Removed before the model saw it</p><div class="dlp-swaps">${swaps(found)}</div>`;
  if (back.length) html += `<p class="dlp-result-sub">Removed from the answer before the employee saw it</p><div class="dlp-swaps">${swaps(back)}</div>`;
  if (st === 'waiting') html += '<p class="dlp-result-sub">Waiting for the answer…</p>';
  return {cls: 'lane-' + d.lane, html};
}
