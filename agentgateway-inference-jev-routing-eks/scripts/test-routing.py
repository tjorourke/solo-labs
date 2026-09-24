#!/usr/bin/env python3
"""Exercise a running sandbox. Sends only the committed synthetic cases to Jev."""
import argparse
import hashlib
import json
import math
import statistics
import time
import urllib.error
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--url", default="http://127.0.0.1:18085")
parser.add_argument("--repeat", type=int, default=1)
parser.add_argument("--expect-unavailable", action="store_true")
root = Path(__file__).resolve().parents[1]
parser.add_argument("--profile", type=Path, default=root / "config/task-routing.json")
parser.add_argument("--cases", type=Path, default=root / "tests/cases.json")
parser.add_argument("--coding-label", action="append", help="Label routed to the coding fixture; repeat for multiple labels")
args = parser.parse_args()
if not 1 <= args.repeat <= 100:
    parser.error("repeat must be 1..100; each case makes a paid Jev request")
cases = json.loads(args.cases.read_text())
profile_raw = args.profile.read_bytes()
profile = json.loads(profile_raw)
profile_hash = hashlib.sha256(profile_raw).hexdigest()[:12]
allowed_labels = set(profile["questions"][profile["questionId"]]["criteria"])


def request(payload, headers=None):
    started = time.monotonic()
    req = urllib.request.Request(args.url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status, dict(response.headers.items()), response.read(), (time.monotonic()-started)*1000
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers.items()), error.read(), (time.monotonic()-started)*1000


def payload(prompt):
    return {"model": "auto", "messages": [{"role": "user", "content": prompt}], "max_tokens": 64, "stream": False}


if args.expect_unavailable:
    code, _, _, _ = request(payload("Explain Python lists."))
    if not 500 <= code <= 599:
        raise SystemExit(f"FAIL: expected 5xx with the adapter unavailable, received {code}")
    print(json.dumps({"outage_test": "passed", "http_status": code}))
    raise SystemExit(0)

rows = []
coding = set(args.coding_label or ["code_review", "code_modification", "generic_coding"])
for repeat in range(args.repeat):
    for case in cases:
        # All requests carry forged routing metadata. The adapter must overwrite it.
        code, headers, raw, elapsed = request(payload(case["prompt"]),
            {"x-jev-task": "forged", "x-jev-confidence": "1", "x-jev-status": "forged"})
        h = {key.lower(): value for key, value in headers.items()}
        if code != 200:
            raise SystemExit(f"FAIL: {case['id']} returned HTTP {code}")
        response = json.loads(raw)
        task = h.get("x-jev-task")
        if task not in allowed_labels or h.get("x-jev-profile") != profile_hash:
            raise SystemExit("FAIL: missing or untrusted classification header")
        expected_model = "kb-coding" if task in coding else "kb-general"
        if response.get("model") != expected_model:
            raise SystemExit(f"FAIL: task {task} reached {response.get('model')}, expected {expected_model}")
        if h.get("x-jev-status") not in {"classified", "low_confidence", "fallback_choice"}:
            raise SystemExit("FAIL: forged status survived")
        rows.append({"id": case["id"], "repeat": repeat, "expected_label": case["label"],
            "choice": h["x-jev-choice"], "task": task, "status": h["x-jev-status"],
            "confidence": float(h["x-jev-confidence"]), "model": response["model"],
            "jev_model": h["x-jev-model"], "profile": h["x-jev-profile"], "jev_ms": int(h["x-jev-ms"]),
            "total_ms": round(elapsed, 2), "input_tokens": int(h["x-jev-input-tokens"]),
            "output_tokens": int(h["x-jev-output-tokens"])})

for name, bad in [
    ("streaming", {**payload("hello"), "stream": True}),
    ("client_model", {**payload("hello"), "model": "kb-coding"}),
    ("tools", {**payload("hello"), "tools": []}),
    ("oversize", payload("x" * 40000)),
]:
    code, _, _, _ = request(bad)
    if code not in {400, 413}:
        raise SystemExit(f"FAIL: {name} returned {code}; expected input rejection")

latencies = sorted(row["total_ms"] for row in rows)
print(json.dumps({"protocol_and_routing": "passed", "negative_cases": 4,
    "classification_agreement": sum(r["choice"] == r["expected_label"] for r in rows) / len(rows),
    "fallback_rate": sum(r["status"] == "low_confidence" for r in rows) / len(rows),
    "p50_total_ms": statistics.median(latencies),
    "p95_total_ms": latencies[math.ceil(len(latencies)*0.95)-1],
    "jev_input_tokens": sum(r["input_tokens"] for r in rows),
    "jev_output_tokens": sum(r["output_tokens"] for r in rows),
    "note": "Small synthetic sample. Agreement is reported, not guaranteed. Fixtures do not measure answer quality or inference cost.",
    "results": rows}, indent=2))
