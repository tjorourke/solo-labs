#!/usr/bin/env python3
"""TrustUsBank online banking: the customer-facing web app.

Stdlib only. Serves the public website from site/ at /, the online-banking
dashboard from static/ at /banking/, and a small JSON API over mock, in-memory
accounts. Product settings (the announcement banner, the daily
transfer limit, feature switches, the support line) live in config.json, so a
change request is usually a one-line edit there.

    APP_ENV   staging | production   shown in the header ribbon
    GIT_SHA   the commit this image was built from
    PORT      8080
"""
import json
import os
import threading
import uuid
from datetime import date, datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
STATIC = HERE / "static"   # online banking, at /banking/
SITE = HERE / "site"       # the public website, at /
CONFIG = json.loads((HERE / "config.json").read_text())
APP_ENV = os.environ.get("APP_ENV", "local")
GIT_SHA = os.environ.get("GIT_SHA", "dev")[:7]

CUSTOMER = {"name": "Anna Schmidt", "first_name": "Anna", "customer_id": "C-1001",
            "email": "anna.schmidt@example.de"}

ACCOUNTS = [
    {"id": "giro", "name": "Everyday account", "product": "TrustUs Plus account",
     "iban": "DE89 5001 0517 0000 1001 01", "balance": 6234.18, "currency": "EUR"},
    {"id": "tagesgeld", "name": "Savings", "product": "Easy access savings · 2.75% a year",
     "iban": "DE89 5001 0517 0000 1001 02", "balance": 24110.00, "currency": "EUR"},
    {"id": "card", "name": "Gold credit card", "product": "Spend up to € 5,000",
     "iban": "•••• •••• •••• 4821", "balance": -412.37, "currency": "EUR"},
]

TRANSACTIONS = [
    ("2026-09-30", "giro", "Rhein-Main Logistik GmbH", "September pay", "income", 4850.00),
    ("2026-09-29", "giro", "REWE Sachsenhausen", "Card payment", "groceries", -86.42),
    ("2026-09-29", "card", "Lufthansa", "LH 400 FRA–JFK", "travel", -389.00),
    ("2026-09-28", "giro", "Mainova AG", "Electricity, October", "utilities", -94.00),
    ("2026-09-27", "giro", "Hausverwaltung Berger", "Rent, October", "housing", -1200.00),
    ("2026-09-26", "tagesgeld", "TrustUsBank", "Interest paid", "income", 55.24),
    ("2026-09-25", "giro", "Deutsche Bahn", "Train Frankfurt–Berlin", "travel", -59.90),
    ("2026-09-24", "card", "Zalando SE", "Order 10293847", "shopping", -23.37),
    ("2026-09-23", "giro", "Techniker Krankenkasse", "Health insurance", "insurance", -38.10),
    ("2026-09-22", "giro", "Spotify AB", "Premium Family", "subscriptions", -17.99),
]

_lock = threading.Lock()
_txns = [{"id": uuid.uuid4().hex[:10], "date": d, "account": a, "counterparty": c,
          "reference": r, "category": cat, "amount": amt} for d, a, c, r, cat, amt in TRANSACTIONS]
_sent_today = 0.0


def _iban_ok(iban: str) -> bool:
    s = iban.replace(" ", "").upper()
    if len(s) < 15 or len(s) > 34 or not s[:2].isalpha() or not s[2:4].isdigit():
        return False
    n = "".join(str(int(ch, 36)) for ch in s[4:] + s[:4])
    return int(n) % 97 == 1


def config() -> dict:
    return {**CONFIG, "env": APP_ENV, "sha": GIT_SHA, "customer": CUSTOMER,
            "today": date.today().isoformat(), "sent_today": round(_sent_today, 2)}


def transfer(body: dict) -> tuple[int, dict]:
    global _sent_today
    acc = next((a for a in ACCOUNTS if a["id"] == body.get("from")), None)
    if not acc or acc["id"] == "card":
        return 400, {"error": "Choose the account to pay from."}
    name = (body.get("name") or "").strip()
    iban = (body.get("iban") or "").strip()
    ref = (body.get("reference") or "").strip()[:140]
    try:
        amount = round(float(body.get("amount")), 2)
    except (TypeError, ValueError):
        return 400, {"error": "Enter an amount."}
    if not name:
        return 400, {"error": "Enter the recipient's name."}
    if not _iban_ok(iban):
        return 400, {"error": "That account number does not look right. Check it and try again."}
    if amount <= 0:
        return 400, {"error": "The amount must be more than € 0.00."}
    limit = float(CONFIG["daily_transfer_limit_eur"])
    with _lock:
        if _sent_today + amount > limit:
            left = max(0.0, limit - _sent_today)
            return 400, {"error": f"This exceeds your daily transfer limit. You can send € {left:,.2f} more today."}
        if amount > acc["balance"]:
            return 400, {"error": "There is not enough money in this account."}
        instant = bool(body.get("instant")) and CONFIG["features"].get("instant_payments", False)
        acc["balance"] = round(acc["balance"] - amount, 2)
        _sent_today += amount
        tx = {"id": uuid.uuid4().hex[:10], "date": date.today().isoformat(), "account": acc["id"],
              "counterparty": name, "reference": ref or "Überweisung", "category": "transfer",
              "amount": -amount}
        _txns.insert(0, tx)
    return 200, {"ok": True, "transaction": tx, "instant": instant,
                 "arrives": "within 10 seconds" if instant else "next working day",
                 "balance": acc["balance"], "sent_today": round(_sent_today, 2)}


class H(BaseHTTPRequestHandler):
    server_version = "TrustUsBank"

    def log_message(self, *args):
        return

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/healthz":
            return self._json(200, {"ok": True, "env": APP_ENV, "sha": GIT_SHA})
        if path == "/api/config":
            return self._json(200, config())
        if path == "/api/accounts":
            return self._json(200, {"accounts": ACCOUNTS,
                                    "as_of": datetime.now(timezone.utc).isoformat(timespec="seconds")})
        if path == "/api/transactions":
            return self._json(200, {"transactions": _txns[:25]})
        if path == "/banking":
            self.send_response(301)
            self.send_header("Location", "/banking/")
            self.end_headers()
            return
        root, rel = (STATIC, path[len("/banking/"):]) if path.startswith("/banking/") else (SITE, path.lstrip("/"))
        f = root / rel
        if f.is_dir() or not rel:
            f = f / "index.html"
        if not f.resolve().is_relative_to(root.resolve()) or not f.is_file():
            return self._json(404, {"error": "not found"})
        types = {".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "application/javascript",
                 ".svg": "image/svg+xml"}
        body = f.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", types.get(f.suffix, "application/octet-stream"))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/transfers":
            return self._json(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "bad request"})
        code, out = transfer(body)
        return self._json(code, out)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"TrustUsBank online banking ({APP_ENV}, {GIT_SHA}) on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
