#!/usr/bin/env python3
"""Print the gauges the Endpoint Picker reads, one line per replica.

This is the entire input to the scheduling decision. Two numbers off each model server
and an index the picker keeps for itself, and that is the lot.

Run from inside the cluster (scripts/metrics.sh execs it in the loadgen pod).
"""

from __future__ import annotations

import os
import re
import sys
import urllib.request

WANT = {
    "vllm:num_requests_waiting": "waiting",
    "vllm:num_requests_running": "running",
    "vllm:kv_cache_usage_perc": "kv",
    # _total, not the bare name vLLM's docs list: the Prometheus client appends it to
    # every Counter. The documented name matches nothing and reads as zero, so the hit
    # rate prints n/a and looks like a model with prefix caching switched off.
    "vllm:prefix_cache_queries_total": "queries",
    "vllm:prefix_cache_hits_total": "hits",
}

SERIES = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9eE.+-]+)$")


def read(host: str) -> dict[str, float] | None:
    try:
        body = urllib.request.urlopen(f"http://{host}/metrics", timeout=5).read().decode("utf-8", "replace")
    except Exception:
        return None
    vals: dict[str, float] = {}
    for line in body.splitlines():
        if not line or line[0] == "#":
            continue
        m = SERIES.match(line.strip())
        if not m:
            continue
        name, _labels, raw = m.groups()
        key = WANT.get(name)
        if key is None:
            continue
        try:
            vals[key] = vals.get(key, 0.0) + float(raw)
        except ValueError:
            pass
    return vals


def main() -> int:
    replicas = [
        r.strip()
        for r in os.environ.get(
            "REPLICAS",
            "vllm-0.vllm-headless.models.svc.cluster.local:8000,"
            "vllm-1.vllm-headless.models.svc.cluster.local:8000",
        ).split(",")
        if r.strip()
    ]
    print(f"{'replica':<10}{'waiting':>9}{'running':>9}{'kv used':>10}{'prefix hit':>12}")
    for host in replicas:
        short = host.split(".")[0]
        vals = read(host)
        if vals is None:
            print(f"{short:<10}{'unreachable':>40}")
            continue
        q = vals.get("queries", 0.0)
        h = vals.get("hits", 0.0)
        # Cumulative since the replica started, not a rate. It moves slowly once a
        # replica has served a few hundred requests, so compare the DELTA across a run
        # (which is what bench.py reports) rather than this absolute figure.
        rate = f"{100.0 * h / q:.0f}%" if q else "n/a"
        print(
            f"{short:<10}{vals.get('waiting', 0.0):>9.0f}{vals.get('running', 0.0):>9.0f}"
            f"{vals.get('kv', 0.0):>10.2f}{rate:>12}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
