#!/usr/bin/env python3
"""TrustUsBank core-banking MCP: one image, four servers, picked by DOMAIN.

    payments     balances, transactions, payment limits, ECB reference FX rates
    compliance   sanctions screening, AML thresholds, transaction alerts
    credit       customer exposure, affordability
    gdpr         personal data held on a customer, a draft DSGVO Art. 15 response

Everything is mock data for a fictional Frankfurt bank. Each domain is its own
Deployment and its own agentgateway route, so an agent only ever sees the tools of
the one domain its AgentRegistry record grants. Tool names are snake_case: vLLM's
pythonic tool parser, which Gemma 3 uses, cannot read a hyphen.
"""
import os
from datetime import date

from mcp_base import serve

CUSTOMERS = {
    "C-1001": {"name": "Anna Schmidt", "born": "1984-03-12", "city": "Frankfurt am Main",
               "email": "anna.schmidt@example.de", "phone": "+49 69 5550 1001",
               "address": "Mainzer Landstraße 41, 60329 Frankfurt am Main",
               "tax_id": "DE 12 345 678 901", "segment": "retail", "since": "2011-06-01",
               "net_monthly_income_eur": 4850, "monthly_obligations_eur": 1320, "schufa_score": 97.1},
    "C-1002": {"name": "Mehmet Yilmaz", "born": "1977-11-02", "city": "Offenbach am Main",
               "email": "m.yilmaz@example.de", "phone": "+49 69 5550 1002",
               "address": "Kaiserstraße 8, 63065 Offenbach am Main",
               "tax_id": "DE 98 765 432 109", "segment": "sme", "since": "2016-02-15",
               "net_monthly_income_eur": 7200, "monthly_obligations_eur": 3900, "schufa_score": 88.4},
    "C-1003": {"name": "Claire Dubois", "born": "1991-07-24", "city": "Wiesbaden",
               "email": "claire.dubois@example.fr", "phone": "+49 611 5550 1003",
               "address": "Wilhelmstraße 22, 65183 Wiesbaden",
               "tax_id": "DE 55 444 333 222", "segment": "private_banking", "since": "2019-09-30",
               "net_monthly_income_eur": 12400, "monthly_obligations_eur": 2100, "schufa_score": 98.6},
}

ACCOUNTS = {
    "DE89500105170000100101": {"customer": "C-1001", "type": "Girokonto", "balance_eur": 6234.18,
                               "daily_limit_eur": 5000, "used_today_eur": 1200.00},
    "DE89500105170000100102": {"customer": "C-1001", "type": "Tagesgeld", "balance_eur": 24110.00,
                               "daily_limit_eur": 10000, "used_today_eur": 0.0},
    "DE89500105170000200201": {"customer": "C-1002", "type": "Geschäftskonto", "balance_eur": 48920.55,
                               "daily_limit_eur": 25000, "used_today_eur": 18750.00},
    "DE89500105170000300301": {"customer": "C-1003", "type": "Girokonto", "balance_eur": 182300.40,
                               "daily_limit_eur": 50000, "used_today_eur": 0.0},
}

TRANSACTIONS = {
    "DE89500105170000100101": [
        ("2026-09-30", "SEPA credit", "Gehalt Rhein-Main Logistik GmbH", 4850.00),
        ("2026-09-29", "Card", "REWE Sachsenhausen", -86.42),
        ("2026-09-28", "SEPA debit", "Mainova AG Strom", -94.00),
        ("2026-09-27", "Instant payment", "Miete Okt — Hausverwaltung Berger", -1200.00),
        ("2026-09-25", "Card", "Deutsche Bahn", -59.90),
    ],
    "DE89500105170000200201": [
        ("2026-09-30", "SEPA credit", "Invoice 2026-0911 Kaya Bau GmbH", 12600.00),
        ("2026-09-30", "SWIFT", "Supplier Istanbul Tekstil A.S. (TRY)", -18750.00),
        ("2026-09-26", "Cash deposit", "Branch Offenbach", 9800.00),
        ("2026-09-24", "Cash deposit", "Branch Offenbach", 9500.00),
        ("2026-09-20", "SEPA debit", "Finanzamt Offenbach USt", -4210.00),
    ],
    "DE89500105170000300301": [
        ("2026-09-29", "SEPA credit", "Dividende Depot", 3120.00),
        ("2026-09-22", "SWIFT", "Notaire Lyon — property deposit", -45000.00),
    ],
}

# ECB euro foreign exchange reference rates, 30 Sep 2026 (mock): units per 1 EUR.
ECB_RATES = {"USD": 1.0912, "GBP": 0.8431, "CHF": 0.9378, "JPY": 162.41, "PLN": 4.2875,
             "TRY": 37.882, "SEK": 11.204, "CZK": 25.118, "DKK": 7.4589, "NOK": 11.682}

# Consolidated screening list (EU/UN/OFAC style), mock entries only.
SANCTIONS = [
    {"name": "Viktor Orlenko", "list": "EU 2014/269/CFSP", "country": "RU", "reason": "Asset freeze"},
    {"name": "Golden Strait Shipping LLC", "list": "OFAC SDN", "country": "AE", "reason": "Sanctions evasion"},
    {"name": "Karim Haddad", "list": "UN 1267", "country": "SY", "reason": "Terrorist financing"},
]
HIGH_RISK_COUNTRIES = {"IR", "KP", "MM", "SY", "RU", "BY"}

# Processing purposes and legal bases (DSGVO Art. 6), the same for every customer here.
PURPOSES = [
    {"purpose": "Account management and payments", "basis": "Art. 6(1)(b) contract", "retention": "10 years after closure (§ 257 HGB, § 147 AO)"},
    {"purpose": "Anti-money-laundering checks", "basis": "Art. 6(1)(c) legal obligation (GwG)", "retention": "5 years after the business relationship (§ 8 GwG)"},
    {"purpose": "Credit scoring with SCHUFA", "basis": "Art. 6(1)(f) legitimate interest", "retention": "Until the score is superseded"},
    {"purpose": "Marketing emails", "basis": "Art. 6(1)(a) consent", "retention": "Until consent is withdrawn"},
]
RECIPIENTS = ["SCHUFA Holding AG", "Bundeszentralamt für Steuern", "Payment networks (SEPA, SWIFT)",
              "Google Cloud Germany (GCD Berlin) as processor"]


def _account(args):
    acc = (args.get("account_id") or args.get("iban") or "").replace(" ", "").upper()
    if acc not in ACCOUNTS:
        raise ValueError(f"unknown account {acc or '(none)'}; known: {', '.join(ACCOUNTS)}")
    return acc, ACCOUNTS[acc]


def _customer(args):
    cid = (args.get("customer_id") or "").strip().upper()
    if cid not in CUSTOMERS:
        # Accept a name too, which is how a person asks.
        by_name = [k for k, c in CUSTOMERS.items() if c["name"].lower() == cid.lower()]
        if not by_name:
            raise ValueError(f"unknown customer {cid or '(none)'}; known: {', '.join(CUSTOMERS)}")
        cid = by_name[0]
    return cid, CUSTOMERS[cid]


def _num(args, key):
    try:
        return float(args.get(key))
    except (TypeError, ValueError):
        raise ValueError(f"{key} must be a number")


# --- payments ---------------------------------------------------------------

def get_account_balance(args):
    acc, a = _account(args)
    return {"account_id": acc, "type": a["type"], "customer_id": a["customer"],
            "balance_eur": a["balance_eur"], "as_of": "2026-10-01T08:00:00+02:00"}


def list_transactions(args):
    acc, _ = _account(args)
    limit = int(args.get("limit") or 5)
    rows = TRANSACTIONS.get(acc, [])[:limit]
    return {"account_id": acc, "transactions": [
        {"date": d, "kind": k, "counterparty": c, "amount_eur": amt} for d, k, c, amt in rows]}


def check_payment_limit(args):
    acc, a = _account(args)
    amount = _num(args, "amount_eur")
    left = a["daily_limit_eur"] - a["used_today_eur"]
    ok = amount <= left and amount <= a["balance_eur"]
    reason = "within limit" if ok else (
        "exceeds the remaining daily limit" if amount > left else "insufficient balance")
    return {"account_id": acc, "amount_eur": amount, "daily_limit_eur": a["daily_limit_eur"],
            "remaining_today_eur": round(left, 2), "allowed": ok, "reason": reason}


def get_ecb_fx_rate(args):
    cur = (args.get("currency") or "").upper()
    if cur not in ECB_RATES:
        raise ValueError(f"no ECB reference rate for {cur or '(none)'}; known: {', '.join(ECB_RATES)}")
    out = {"currency": cur, "per_eur": ECB_RATES[cur], "source": "ECB euro reference rate",
           "date": "2026-09-30"}
    if args.get("amount_eur") not in (None, ""):
        out["amount_eur"] = _num(args, "amount_eur")
        out["converted"] = round(out["amount_eur"] * ECB_RATES[cur], 2)
    return out


# --- compliance -------------------------------------------------------------

def screen_sanctions(args):
    name = (args.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    words = set(name.lower().split())
    hits = [s for s in SANCTIONS if words & set(s["name"].lower().split())]
    exact = [s for s in hits if s["name"].lower() == name.lower()]
    result = "match" if exact else ("possible_match" if hits else "clear")
    return {"screened": name, "result": result, "hits": hits,
            "lists_checked": ["EU consolidated", "UN", "OFAC SDN"], "date": str(date.today()),
            "legal_basis": {"match": "Do not release: freeze the funds (Art. 2 Reg. (EU) 269/2014 for EU listings; "
                                     "OFAC SDN for USD clearing) and report to the FIU (§ 43 GwG).",
                            "possible_match": "Hold the payment and verify identity before release (§ 15 GwG).",
                            "clear": "No restriction: the payment may proceed."}[result]}


def check_aml_threshold(args):
    amount = _num(args, "amount_eur")
    country = (args.get("country") or "DE").upper()
    cash = str(args.get("cash", "false")).lower() in ("true", "1", "yes")
    flags = []
    if cash and amount >= 10000:
        flags.append("Cash of EUR 10,000 or more: identify the customer (§ 10 Abs. 3 GwG)")
    if amount >= 15000:
        flags.append("Occasional transaction of EUR 15,000 or more: due diligence applies (§ 10 GwG)")
    if country in HIGH_RISK_COUNTRIES:
        flags.append(f"{country} is a high-risk third country: enhanced due diligence (§ 15 GwG)")
    return {"amount_eur": amount, "country": country, "cash": cash, "flags": flags,
            "action": "file a suspicious activity report via goAML if unexplained" if len(flags) > 1
            else ("enhanced checks" if flags else "none")}


def get_transaction_alerts(args):
    acc, a = _account(args)
    rows = TRANSACTIONS.get(acc, [])
    alerts = []
    cash = [r for r in rows if r[1] == "Cash deposit"]
    if len(cash) >= 2 and all(9000 <= r[3] < 10000 for r in cash):
        alerts.append({"rule": "structuring", "detail": f"{len(cash)} cash deposits just under EUR 10,000",
                       "transactions": [r[0] for r in cash],
                       "legal_basis": "Possible evasion of the § 10 Abs. 3 GwG cash threshold: "
                                      "report to the FIU via goAML if unexplained (§ 43 GwG)"})
    for d, k, c, amt in rows:
        if k == "SWIFT" and abs(amt) >= 15000:
            alerts.append({"rule": "large_cross_border", "detail": f"{c}: EUR {abs(amt):,.2f}", "transactions": [d],
                           "legal_basis": "Ongoing monitoring of the business relationship (§ 10 Abs. 1 Nr. 5 GwG)"})
    return {"account_id": acc, "customer_id": a["customer"], "alerts": alerts}


# --- credit -----------------------------------------------------------------

def get_customer_exposure(args):
    cid, c = _customer(args)
    accounts = {k: v for k, v in ACCOUNTS.items() if v["customer"] == cid}
    loans = {"C-1001": [{"product": "Baufinanzierung", "outstanding_eur": 212000, "rate_pct": 3.4}],
             "C-1002": [{"product": "Betriebsmittelkredit", "outstanding_eur": 85000, "rate_pct": 6.1},
                        {"product": "Leasing Transporter", "outstanding_eur": 31000, "rate_pct": 5.2}],
             "C-1003": []}.get(cid, [])
    return {"customer_id": cid, "name": c["name"], "segment": c["segment"],
            "deposits_eur": round(sum(a["balance_eur"] for a in accounts.values()), 2),
            "loans": loans, "total_lending_eur": sum(l["outstanding_eur"] for l in loans),
            "schufa_score": c["schufa_score"]}


def assess_affordability(args):
    cid, c = _customer(args)
    amount = _num(args, "loan_amount_eur")
    months = int(_num(args, "term_months"))
    rate = float(args.get("rate_pct") or 5.0) / 100 / 12
    instalment = amount * rate / (1 - (1 + rate) ** -months) if rate else amount / months
    free = c["net_monthly_income_eur"] - c["monthly_obligations_eur"]
    ratio = (c["monthly_obligations_eur"] + instalment) / c["net_monthly_income_eur"]
    return {"customer_id": cid, "loan_amount_eur": amount, "term_months": months,
            "monthly_instalment_eur": round(instalment, 2), "free_income_before_eur": free,
            "debt_service_ratio": round(ratio, 3), "policy_max_ratio": 0.4,
            "decision": "approve" if ratio <= 0.4 else ("refer" if ratio <= 0.5 else "decline")}


# --- gdpr -------------------------------------------------------------------

def find_personal_data(args):
    cid, c = _customer(args)
    return {"customer_id": cid, "master_data": {k: c[k] for k in
            ("name", "born", "address", "email", "phone", "tax_id")},
            "accounts": [k for k, v in ACCOUNTS.items() if v["customer"] == cid],
            "systems": ["Core banking (Berlin GCD)", "CRM", "SCHUFA interface", "Marketing consent store"],
            "customer_since": c["since"]}


def list_processing_purposes(args):
    cid, _ = _customer(args)
    return {"customer_id": cid, "purposes": PURPOSES, "recipients": RECIPIENTS,
            "third_country_transfers": "none: all processing in Germany (GCD Berlin)"}


def draft_art15_response(args):
    cid, c = _customer(args)
    return {"customer_id": cid, "deadline": "one month from receipt (Art. 12(3) DSGVO)",
            "sections": ["Confirmation that personal data is processed (Art. 15(1))",
                         "Purposes and legal bases", "Categories of data", "Recipients",
                         "Retention periods", "Right to rectification, erasure, restriction and objection",
                         "Right to complain to the Hessischer Beauftragter für Datenschutz",
                         "Source of data not collected from the customer (SCHUFA)",
                         "A copy of the data (Art. 15(3))"],
            "addressee": c["name"], "address": c["address"],
            "note": "Use find_personal_data and list_processing_purposes for the content."}


def _t(name, desc, props, required=()):
    return {"name": name, "description": desc, "inputSchema": {
        "type": "object", "properties": props, "required": list(required)}}


S, N = {"type": "string"}, {"type": "number"}
ACC = {"account_id": {**S, "description": "IBAN, e.g. DE89500105170000100101"}}
CUS = {"customer_id": {**S, "description": "Customer id, e.g. C-1001, or the customer's name"}}

DOMAINS = {
    "payments": [
        (_t("get_account_balance", "Current balance of an account.", ACC, ["account_id"]), get_account_balance),
        (_t("list_transactions", "Most recent transactions on an account.",
            {**ACC, "limit": N}, ["account_id"]), list_transactions),
        (_t("check_payment_limit", "Whether a payment of amount_eur fits the account's remaining daily limit and balance.",
            {**ACC, "amount_eur": N}, ["account_id", "amount_eur"]), check_payment_limit),
        (_t("get_ecb_fx_rate", "ECB euro reference rate for a currency, optionally converting amount_eur.",
            {"currency": {**S, "description": "ISO code, e.g. USD"}, "amount_eur": N}, ["currency"]), get_ecb_fx_rate),
    ],
    "compliance": [
        (_t("screen_sanctions", "Screen a person or company name against EU, UN and OFAC sanctions lists.",
            {"name": S}, ["name"]), screen_sanctions),
        (_t("check_aml_threshold", "Which German AML (GwG) thresholds a transaction triggers.",
            {"amount_eur": N, "country": {**S, "description": "ISO country code of the counterparty"},
             "cash": {"type": "boolean"}}, ["amount_eur"]), check_aml_threshold),
        (_t("get_transaction_alerts", "Monitoring alerts (structuring, large cross-border) on an account.",
            ACC, ["account_id"]), get_transaction_alerts),
    ],
    "credit": [
        (_t("get_customer_exposure", "A customer's deposits, loans, total lending and SCHUFA score.",
            CUS, ["customer_id"]), get_customer_exposure),
        (_t("assess_affordability", "Monthly instalment and debt-service ratio for a new loan, against the 40% policy.",
            {**CUS, "loan_amount_eur": N, "term_months": N, "rate_pct": N},
            ["customer_id", "loan_amount_eur", "term_months"]), assess_affordability),
    ],
    "gdpr": [
        (_t("find_personal_data", "Every item of personal data the bank holds on a customer, and where.",
            CUS, ["customer_id"]), find_personal_data),
        (_t("list_processing_purposes", "Why the bank processes a customer's data, the legal basis, recipients and retention.",
            CUS, ["customer_id"]), list_processing_purposes),
        (_t("draft_art15_response", "The structure and deadline of a DSGVO Art. 15 subject access response.",
            CUS, ["customer_id"]), draft_art15_response),
    ],
}

if __name__ == "__main__":
    domain = os.environ.get("DOMAIN", "payments")
    entries = DOMAINS[domain]
    serve(f"trustusbank-{domain}", [t for t, _ in entries], {t["name"]: fn for t, fn in entries})
