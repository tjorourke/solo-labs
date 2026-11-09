"""Small FastMCP server used as an externally hosted MCP in the lab.

One file, four services, picked with SERVICE:
  health-records     (cloud-a)  patient search, appointments, full patient record
  finance-payments   (cloud-a)  account balances, transactions, refunds
  telco-network      (cloud-b)  cell-site status, outages, cell-site reset
  compute-inventory  (cloud-b)  VMs, VM detail, VM restart, cost per VM
Each service has one sensitive tool that the lab hides from developers at the gateway.
All data is made up and fixed so the demo is repeatable.
Tested with fastmcp 4.1.6 (pinned in requirements.txt and in scripts/lib.sh).
"""
import os

from fastmcp import FastMCP

SERVICE = os.environ.get("SERVICE", "compute-inventory")
mcp = FastMCP(SERVICE)

if SERVICE == "health-records":
    PATIENTS = {
        "PT-104233": {"name": "Amelia Hart", "born": "1984-03-12", "nhs_style_id": "943 476 5919", "clinic": "Riverside GP",
                      "conditions": ["asthma"], "allergies": ["penicillin"], "medications": ["salbutamol inhaler"]},
        "PT-104871": {"name": "Daniel Okafor", "born": "1971-11-02", "nhs_style_id": "485 777 3456", "clinic": "Riverside GP",
                      "conditions": ["type 2 diabetes"], "allergies": [], "medications": ["metformin 500mg"]},
        "PT-105020": {"name": "Priya Nair", "born": "1992-07-25", "nhs_style_id": "401 023 2137", "clinic": "Northgate Health Centre",
                      "conditions": [], "allergies": ["latex"], "medications": []},
    }
    APPOINTMENTS = [
        {"patient_id": "PT-104233", "date": "2026-11-12", "time": "09:20", "clinic": "Riverside GP", "type": "asthma review"},
        {"patient_id": "PT-104871", "date": "2026-11-12", "time": "10:40", "clinic": "Riverside GP", "type": "HbA1c blood test"},
        {"patient_id": "PT-105020", "date": "2026-11-13", "time": "14:00", "clinic": "Northgate Health Centre", "type": "new patient check"},
    ]

    @mcp.tool
    def search_patients(surname: str = "", clinic: str = "") -> list[dict]:
        """Find patients by surname or clinic. Returns IDs and clinic only, no clinical data."""
        return [
            {"patient_id": pid, "surname": p["name"].split()[-1], "clinic": p["clinic"]}
            for pid, p in PATIENTS.items()
            if (not surname or p["name"].split()[-1].lower() == surname.lower()) and (not clinic or p["clinic"] == clinic)
        ]

    @mcp.tool
    def get_appointments(date: str = "", clinic: str = "") -> list[dict]:
        """List booked appointments, optionally for one date (YYYY-MM-DD) or clinic."""
        return [a for a in APPOINTMENTS if (not date or a["date"] == date) and (not clinic or a["clinic"] == clinic)]

    @mcp.tool
    def get_patient_record(patient_id: str) -> dict:
        """Return the full patient record, including identifiers, conditions and medication. Sensitive."""
        return {"patient_id": patient_id, **PATIENTS.get(patient_id, {"error": "not found"})}

elif SERVICE == "finance-payments":
    ACCOUNTS = {
        "ACC-20-45-77-10293847": {"holder": "Northwind Trading Ltd", "currency": "GBP", "balance": 18240.55},
        "ACC-20-45-77-55510321": {"holder": "Harbour Lane Bakery", "currency": "GBP", "balance": 3120.90},
    }
    TRANSACTIONS = [
        {"id": "TXN-88213", "account": "ACC-20-45-77-10293847", "date": "2026-11-03", "amount": -1450.00, "description": "Card payment, office supplies"},
        {"id": "TXN-88219", "account": "ACC-20-45-77-10293847", "date": "2026-11-05", "amount": 9800.00, "description": "Customer invoice INV-2207"},
        {"id": "TXN-88240", "account": "ACC-20-45-77-55510321", "date": "2026-11-06", "amount": -64.99, "description": "Card payment, duplicate charge"},
        {"id": "TXN-88241", "account": "ACC-20-45-77-55510321", "date": "2026-11-06", "amount": -64.99, "description": "Card payment, flour supplier"},
    ]

    @mcp.tool
    def get_account_balance(account_id: str) -> dict:
        """Return the current balance of one account."""
        return {"account_id": account_id, **ACCOUNTS.get(account_id, {"error": "not found"})}

    @mcp.tool
    def list_transactions(account_id: str, since: str = "") -> list[dict]:
        """List transactions on an account, optionally since a date (YYYY-MM-DD)."""
        return [t for t in TRANSACTIONS if t["account"] == account_id and (not since or t["date"] >= since)]

    @mcp.tool
    def issue_refund(transaction_id: str, amount: float, reason: str) -> dict:
        """Refund all or part of a transaction. Moves money; the platform team hides this from developers."""
        return {"refund_id": "RFD-" + transaction_id.split("-")[-1], "transaction_id": transaction_id, "amount": amount, "status": "submitted"}

elif SERVICE == "telco-network":
    SITES = {
        "LDN-CS-0142": {"area": "London Bridge", "status": "degraded", "technology": "5G NR", "load_pct": 91, "alarms": ["high PRB utilisation"]},
        "LDN-CS-0217": {"area": "Canary Wharf", "status": "up", "technology": "5G NR", "load_pct": 64, "alarms": []},
        "MAN-CS-0033": {"area": "Manchester Piccadilly", "status": "down", "technology": "LTE", "load_pct": 0, "alarms": ["S1 link lost"]},
    }
    OUTAGES = [
        {"id": "OUT-5521", "site": "MAN-CS-0033", "started": "2026-11-09T06:12:00Z", "impact": "approx. 4,100 subscribers", "status": "open"},
        {"id": "OUT-5507", "site": "LDN-CS-0142", "started": "2026-11-08T17:40:00Z", "impact": "slow data in peak hour", "status": "monitoring"},
    ]

    @mcp.tool
    def get_cell_site_status(site_id: str) -> dict:
        """Return the status, load and active alarms for one cell site, such as LDN-CS-0142."""
        return {"site_id": site_id, **SITES.get(site_id, {"status": "unknown"})}

    @mcp.tool
    def list_outages(status: str = "") -> list[dict]:
        """List network outages, optionally only those with a status such as open."""
        return [o for o in OUTAGES if not status or o["status"] == status]

    @mcp.tool
    def reset_cell_site(site_id: str) -> str:
        """Reset a cell site. Drops every call on the site; the platform team hides this from developers."""
        return f"reset scheduled for {site_id}"

else:  # compute-inventory
    VMS = {
        "checkout-api-01": {"region": "eu-london-1", "state": "running", "size": "4 vCPU / 16 GiB", "owner": "payments"},
        "checkout-api-02": {"region": "eu-london-1", "state": "stopped", "size": "4 vCPU / 16 GiB", "owner": "payments"},
        "ledger-batch-07": {"region": "eu-frankfurt-1", "state": "running", "size": "16 vCPU / 64 GiB", "owner": "finance-data"},
    }
    # Last month's cost per VM, so a later cross-server question has a real answer.
    VM_COSTS = {
        "checkout-api-01": {"month": "2026-10", "gbp": 1840.20},
        "checkout-api-02": {"month": "2026-10", "gbp": 960.45},
        "ledger-batch-07": {"month": "2026-10", "gbp": 6215.80},
    }

    @mcp.tool
    def list_vms(region: str = "") -> list[dict]:
        """List VMs, optionally for one region such as eu-london-1."""
        return [{"name": n, **v} for n, v in VMS.items() if not region or v["region"] == region]

    @mcp.tool
    def get_vm(name: str) -> dict:
        """Return the region, state, size and owning team of one VM."""
        return {"name": name, **VMS.get(name, {"state": "unknown"})}

    @mcp.tool
    def get_cost_by_vm(name: str = "") -> list[dict]:
        """Return last month's cost in GBP for each VM, or for one VM by name."""
        return [{"name": n, **v} for n, v in VM_COSTS.items() if not name or n == name]

    @mcp.tool
    def restart_vm(name: str) -> str:
        """Restart a VM. The platform team hides this from developers."""
        return f"restart requested for {name}"


if __name__ == "__main__":
    # Runs as a plain process on the laptop, outside the kind cluster. scripts/quick.sh servers-up sets
    # SERVICE, PORT (8001 to 8004) and BIND_HOST.
    mcp.run(
        transport="http",
        host=os.environ.get("BIND_HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8001")),
        path="/mcp",
    )
