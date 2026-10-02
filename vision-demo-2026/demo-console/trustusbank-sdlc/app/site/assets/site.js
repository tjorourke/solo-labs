// TrustUsBank public website: environment ribbon, announcement banner and support
// line from the app's settings (config.json via api/config), plus page widgets.
(function () {
  const $ = (s) => document.querySelector(s);
  const eur = (n, d = 2) => "€ " + Number(n).toLocaleString("de-DE", { minimumFractionDigits: d, maximumFractionDigits: d });
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  // Pages live one level deep at most, so the API is always beside index.html.
  const base = document.documentElement.dataset.base || "";

  // Mark the current page in the main navigation.
  const page = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".mainnav a").forEach((a) => {
    if (a.getAttribute("href") === page) a.classList.add("active");
  });

  fetch(base + "api/config").then((r) => (r.ok ? r.json() : null)).then((cfg) => {
    if (!cfg) return;
    const env = String(cfg.env || "local").toLowerCase();
    const rib = $("#envRibbon");
    if (rib && (env === "staging" || env === "production")) {
      rib.hidden = false;
      rib.className = "env-ribbon " + env;
      rib.innerHTML = (env === "staging" ? "STAGING · preview environment, not for customers · build " : "Production · build ") +
        `<code>${esc(cfg.sha)}</code>`;
    }
    if (cfg.announcement && $("#announcement")) {
      $("#announcement").hidden = false;
      $("#announcement").textContent = cfg.announcement;
    }
    document.querySelectorAll("[data-support-phone]").forEach((el) => { el.textContent = cfg.support_phone; });
    document.querySelectorAll("[data-transfer-limit]").forEach((el) => { el.textContent = eur(cfg.daily_transfer_limit_eur, 0); });
    const instant = cfg.features && cfg.features.instant_payments;
    document.querySelectorAll("[data-instant]").forEach((el) => { el.hidden = !instant; });
    document.querySelectorAll("[data-no-instant]").forEach((el) => { el.hidden = !!instant; });
    const b = $("#build");
    if (b) b.textContent = `${env} · ${cfg.sha}`;
  }).catch(() => {});

  // Loan calculator (loans.html).
  const amt = $("#loanAmount"), term = $("#loanTerm");
  if (amt && term) {
    const APR = 0.0549;
    const calc = () => {
      const p = Number(amt.value), n = Number(term.value), r = APR / 12;
      const m = (p * r) / (1 - Math.pow(1 + r, -n));
      $("#loanAmountOut").textContent = eur(p, 0);
      $("#loanTermOut").textContent = n + " months";
      $("#loanMonthly").textContent = eur(m);
      $("#loanTotal").textContent = eur(m * n);
      $("#loanInterest").textContent = eur(m * n - p);
    };
    amt.addEventListener("input", calc);
    term.addEventListener("input", calc);
    calc();
  }

  // Contact form (help.html): no backend, a confirmation only.
  const form = $("#contactForm");
  if (form) {
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      $("#contactMsg").textContent = "Thank you. Your message has been received; we reply within one working day.";
      form.reset();
    });
  }
})();
