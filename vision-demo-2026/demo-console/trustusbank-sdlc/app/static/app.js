// TrustUsBank online banking dashboard.
const $ = (id) => document.getElementById(id);
const eur = (n) => (n < 0 ? "−" : "") + "€ " + Math.abs(n).toLocaleString("de-DE", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const ICONS = { income: "↓", groceries: "🛒", travel: "✈", utilities: "⚡", housing: "🏠", insurance: "☂",
  subscriptions: "♫", shopping: "🛍", transfer: "↗" };
const ACC_LABEL = { giro: "Everyday", tagesgeld: "Savings", card: "Credit card" };

let cfg = {}, accounts = [], txns = [], filter = "all", freshId = null;

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}

function renderConfig() {
  const env = (cfg.env || "local").toLowerCase();
  const rib = $("envRibbon");
  if (env === "staging" || env === "production") {
    rib.hidden = false;
    rib.className = "env-ribbon " + env;
    rib.innerHTML = (env === "staging" ? "STAGING · preview environment, not for customers · build " : "Production · build ") +
      `<code>${esc(cfg.sha)}</code>`;
  }
  $("build").textContent = `${env} · ${cfg.sha}`;
  const hour = new Date().getHours();
  const hello = hour < 11 ? "Guten Morgen" : hour < 18 ? "Guten Tag" : "Guten Abend";
  $("greeting").textContent = `${hello}, ${cfg.customer.first_name}`;
  $("userName").textContent = cfg.customer.name;
  $("avatar").textContent = cfg.customer.name.split(" ").map((p) => p[0]).join("");
  $("today").textContent = new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  $("supportPhone").textContent = cfg.support_phone;
  if (cfg.announcement) {
    $("announcement").hidden = false;
    $("announcementText").textContent = cfg.announcement;
  }
  $("instantRow").hidden = !cfg.features.instant_payments;
  const ins = !!cfg.features.spending_insights;
  $("insights").hidden = !ins;
  $("navInsights").hidden = !ins;
  renderLimit(cfg.sent_today);
}

function renderLimit(sent) {
  const limit = Number(cfg.daily_transfer_limit_eur);
  $("limitText").textContent = `${eur(sent)} of ${eur(limit)} used`;
  $("limitBar").style.width = Math.min(100, (sent / limit) * 100) + "%";
}

function renderAccounts() {
  const total = accounts.reduce((s, a) => s + a.balance, 0);
  $("netWorth").textContent = eur(total);
  $("accounts").innerHTML = accounts.map((a, i) => `
    <article class="acct${i === 0 ? " primary" : ""}">
      <div class="acct-top">
        <div><div class="acct-name">${esc(a.name)}</div><div class="acct-product">${esc(a.product)}</div></div>
        <span class="acct-badge">${a.id === "card" ? "Card" : "Account"}</span>
      </div>
      <div class="acct-balance${a.balance < 0 ? " neg" : ""}">${eur(a.balance)}</div>
      <div class="acct-iban">${esc(a.iban)}</div>
    </article>`).join("");
  $("fromAcc").innerHTML = accounts.filter((a) => a.id !== "card")
    .map((a) => `<option value="${a.id}">${esc(a.name)} · ${eur(a.balance)}</option>`).join("");
}

function dayLabel(iso) {
  const d = new Date(iso + "T12:00:00"), t = new Date();
  const y = new Date(); y.setDate(t.getDate() - 1);
  if (d.toDateString() === t.toDateString()) return "Today";
  if (d.toDateString() === y.toDateString()) return "Yesterday";
  return d.toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" });
}

function renderTxns() {
  const rows = txns.filter((t) => filter === "all" || t.account === filter);
  let last = "", html = "";
  for (const t of rows) {
    if (t.date !== last) { html += `<li class="txn-day">${dayLabel(t.date)}</li>`; last = t.date; }
    html += `<li class="txn${t.id === freshId ? " new" : ""}">
      <span class="cat ${t.category}">${ICONS[t.category] || "•"}</span>
      <div><div class="txn-who">${esc(t.counterparty)}</div><div class="txn-ref">${esc(t.reference)}</div></div>
      <div class="txn-amt ${t.amount > 0 ? "pos" : ""}">${t.amount > 0 ? "+" : ""}${eur(t.amount)}<span class="txn-acc">${ACC_LABEL[t.account] || ""}</span></div>
    </li>`;
  }
  $("txns").innerHTML = html || `<li class="txn-day">No transactions</li>`;
  renderSpend();
}

function renderSpend() {
  const by = {};
  for (const t of txns) if (t.amount < 0) by[t.category] = (by[t.category] || 0) - t.amount;
  const rows = Object.entries(by).sort((a, b) => b[1] - a[1]).slice(0, 5);
  const max = rows.length ? rows[0][1] : 1;
  $("spend").innerHTML = rows.map(([c, v]) => `<li><span>${ICONS[c] || "•"} ${c[0].toUpperCase() + c.slice(1)}</span><b>${eur(v)}</b>
    <div class="sbar"><span style="width:${(v / max) * 100}%"></span></div></li>`).join("");
}

function toast(msg) {
  const t = $("toast");
  t.textContent = msg; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), 4000);
}

$("filters").addEventListener("click", (e) => {
  const b = e.target.closest(".chip");
  if (!b) return;
  filter = b.dataset.acc;
  document.querySelectorAll(".chip").forEach((c) => c.classList.toggle("active", c === b));
  renderTxns();
});

$("payForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(e.target), msg = $("payMsg"), btn = $("payBtn");
  const body = Object.fromEntries(f.entries());
  body.instant = f.get("instant") === "on";
  body.amount = String(body.amount || "").replace(",", ".");
  msg.className = "form-msg"; msg.textContent = ""; btn.disabled = true;
  try {
    const r = await api("../api/transfers", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    freshId = r.transaction.id;
    msg.className = "form-msg ok";
    msg.textContent = `${eur(-r.transaction.amount)} sent to ${r.transaction.counterparty}. Arrives ${r.arrives}.`;
    toast("Transfer sent");
    e.target.reset();
    renderLimit(r.sent_today);
    await load();
  } catch (err) {
    msg.className = "form-msg err"; msg.textContent = err.message;
  } finally {
    btn.disabled = false;
  }
});

async function load() {
  const [a, t] = await Promise.all([api("../api/accounts"), api("../api/transactions")]);
  accounts = a.accounts; txns = t.transactions;
  renderAccounts(); renderTxns();
}

(async () => {
  cfg = await api("../api/config");
  renderConfig();
  await load();
})();
