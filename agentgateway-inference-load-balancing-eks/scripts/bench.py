#!/usr/bin/env python3
"""Drive load at the gateway and report what each replica actually did.

Standard library only, so it runs in a plain python:3.12-slim pod with nothing
installed. It is meant to be run from inside the cluster (scripts/bench.sh execs it in
the loadgen pod) so the numbers are not measuring a kubectl port-forward.

Three scenarios, each built to isolate one signal:

  mixed   short and long prompts, no shared prefix. Nothing for the prefix scorer to
          latch onto, so this is the queue and KV-cache signals on their own.

  prefix  two long documents, requests alternating between them, each with a short
          unique question on the end. A prefix-aware scheduler should send every
          document-A request to one replica and every document-B request to the other,
          which is both a perfect cache split and a perfect load split. Round-robin
          puts half of each document on each replica, so both replicas prefill both
          documents and the hit rate roughly halves.

  skew    background load is sent DIRECTLY to one replica, bypassing the gateway, and
          then the measured requests go through the gateway as usual. The gateway is
          not told which replica is busy; it has to read that off the metrics. Under
          round-robin half the measured requests queue behind the background work.

What it reports:

  - time to first token and total time, p50 and p95, over the measured requests only
  - per replica, read straight off each pod's /metrics before and after the run:
    requests finished, prompt tokens processed, and prefix cache hits over queries

The per-replica numbers are the evidence. Latency percentiles move for all sorts of
reasons on a shared cluster; "replica 0 served 48 requests and replica 1 served 2" does
not.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

# ── prompt material ──────────────────────────────────────────────────────────────────
# Two long documents. They have to be long enough to be worth caching (the prefix
# scorer ignores anything shorter than one block) and different from each other from the
# very first token, because the index is built on a prefix: two documents that share an
# opening paragraph share those blocks too, and the scheduler will happily treat them as
# the same conversation.
_DOC_A_SEED = (
    "SERVICE RUNBOOK: payments-ledger. The payments-ledger service records every "
    "settled transaction as an append-only entry and exposes a read model for "
    "reconciliation. It runs three replicas behind a virtual service, writes to a "
    "primary Postgres with one synchronous standby, and publishes a change stream that "
    "the reporting pipeline consumes. Entries are immutable once written; corrections "
    "are recorded as compensating entries carrying a reference to the original. "
)
_DOC_B_SEED = (
    "CHANGE RECORD: mesh-upgrade-2026-04. This record covers the rollout of the service "
    "mesh data plane across the estate, moving workloads off per-pod sidecars and onto "
    "the node-level proxy with per-namespace layer seven policy enforcement. The "
    "rollout is staged by namespace, each stage gated on error rate and tail latency "
    "held within the previous week's envelope for a full business day before the next "
    "stage begins. Rollback is a namespace label change. "
)

_QUESTIONS = [
    "Summarise the failure modes in one paragraph.",
    "What is the first thing to check when latency rises?",
    "Which component owns the rollback decision?",
    "List the preconditions that must hold before a change proceeds.",
    "Where would a partial write leave the system?",
    "What evidence would show the change was safe?",
    "Name the single riskiest step and why.",
    "How would you verify the read path after a restart?",
]

_SHORT_PROMPTS = [
    "What does a 503 from an upstream proxy usually mean?",
    "Explain the difference between p50 and p95 latency.",
    "When is a retry unsafe?",
    "What is a readiness probe for?",
    "Why cap concurrency on a model server?",
    "What does queue depth tell you that CPU does not?",
]


def _document(seed: str, approx_tokens: int) -> str:
    """Repeat a seed paragraph until it is roughly approx_tokens long.

    Four characters per token is the same rough conversion the Endpoint Picker's prefix
    plugin uses on untokenised text, so counting this way keeps the lab's idea of
    "a 3,000 token document" and the scheduler's in the same place.
    """
    target_chars = approx_tokens * 4
    out = []
    n = 0
    i = 0
    while n < target_chars:
        para = f"[section {i}] {seed}"
        out.append(para)
        n += len(para)
        i += 1
    return "".join(out)


# ── measurement ──────────────────────────────────────────────────────────────────────
@dataclass
class Result:
    ok: bool
    ttft: float = 0.0
    total: float = 0.0
    completion_tokens: int = 0
    error: str = ""


@dataclass
class Counters:
    """The handful of vLLM series the lab actually reads."""

    finished: float = 0.0
    prompt_tokens: float = 0.0
    prompt_tokens_cached: float = 0.0
    prefix_queries: float = 0.0
    prefix_hits: float = 0.0
    waiting: float = 0.0
    running: float = 0.0
    kv_usage: float = 0.0


_SERIES = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9eE.+-]+)$")


def scrape(host: str, timeout: float = 5.0) -> Counters:
    """Read one replica's /metrics and pull out the series the lab talks about.

    Counters that carry labels (request_success_total is broken down by finish reason,
    prompt_tokens_total by model) are summed across their label sets, because the lab
    only ever asks "how much did this replica do".

    MIND THE _total SUFFIX. vLLM's own metrics documentation lists these as
    vllm:prefix_cache_queries and vllm:prefix_cache_hits, but the Prometheus client
    appends _total to every Counter, so those are the logical names and not the ones on
    the wire. Matching the documented name finds nothing, and because a missing counter
    reads as zero rather than as an error, the hit rate simply prints n/a and the run
    looks like a model with no prefix caching rather than a parser with a typo.

    vllm:external_prefix_cache_* is a separate pair for an external cache tier and is
    deliberately not summed in here; matching on a prefix rather than the exact name
    would double count it.
    """
    c = Counters()
    try:
        with urllib.request.urlopen(f"http://{host}/metrics", timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception:
        return c
    for line in body.splitlines():
        if not line or line[0] == "#":
            continue
        m = _SERIES.match(line.strip())
        if not m:
            continue
        name, _labels, raw = m.groups()
        try:
            v = float(raw)
        except ValueError:
            continue
        if name == "vllm:request_success_total":
            c.finished += v
        elif name == "vllm:prompt_tokens_total":
            c.prompt_tokens += v
        elif name == "vllm:prefix_cache_queries_total":
            c.prefix_queries += v
        elif name == "vllm:prefix_cache_hits_total":
            c.prefix_hits += v
        elif name == "vllm:prompt_tokens_cached_total":
            c.prompt_tokens_cached += v
        elif name == "vllm:num_requests_waiting":
            c.waiting = v
        elif name == "vllm:num_requests_running":
            c.running = v
        elif name == "vllm:kv_cache_usage_perc":
            c.kv_usage = v
    return c


def chat(
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout: float,
) -> Result:
    """One streaming chat completion, timed.

    Streaming is not decoration. Total time on a queued request and total time on a
    running one look the same from outside; time to FIRST token is where queueing shows
    up, and that only exists if the response is streamed.
    """
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            # Deterministic, so a rerun is comparable and the same prompt produces the
            # same length of work.
            "temperature": 0,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
    ).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    ttft = 0.0
    completion_tokens = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if usage := obj.get("usage"):
                    completion_tokens = usage.get("completion_tokens", 0) or 0
                for ch in obj.get("choices") or []:
                    piece = (ch.get("delta") or {}).get("content")
                    # The first chunk of a stream often carries only the role, with no
                    # content. Timing off that overstates how fast the model was.
                    if piece and not ttft:
                        ttft = time.perf_counter() - started
    except urllib.error.HTTPError as e:
        return Result(ok=False, error=f"HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")
    except Exception as e:  # noqa: BLE001 - the message is the useful part
        return Result(ok=False, error=f"{type(e).__name__}: {e}")
    total = time.perf_counter() - started
    return Result(ok=True, ttft=ttft or total, total=total, completion_tokens=completion_tokens)


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    # Nearest-rank. With 50 samples the difference from an interpolating percentile is
    # not worth the argument about which one a reader assumed.
    k = max(0, min(len(s) - 1, int(round(p / 100.0 * len(s) + 0.5)) - 1))
    return s[k]


# ── scenarios ────────────────────────────────────────────────────────────────────────
def build_prompts(
    scenario: str,
    n: int,
    doc_tokens: int,
    rng: random.Random,
    nonce: str = "",
    docs_count: int = 2,
    shuffle: bool = False,
) -> list[str]:
    if scenario == "prefix":
        pre = f"[{nonce}] " if nonce else ""
        # Each document gets its own seed line, so they diverge at the first token and
        # the scheduler's prefix index treats them as genuinely separate conversations.
        docs = [
            pre + f"[corpus {d}] " + _document(_DOC_A_SEED if d % 2 else _DOC_B_SEED, doc_tokens)
            for d in range(docs_count)
        ]
        order = [i % docs_count for i in range(n)]
        if shuffle:
            # Cycling documents in order is a trap. Any scheduler that hands out runs of
            # consecutive requests to one replica then gives that replica a run of
            # CONSECUTIVE DOCUMENTS, which is a smaller working set than the corpus and
            # fits in a cache the whole corpus would not. That looks exactly like
            # cache-aware routing and is nothing of the kind: it is the load generator's
            # ordering interacting with the scheduler's batch size. Shuffling removes
            # the correlation so the measurement is about the scheduler.
            rng.shuffle(order)
        return [
            f"{docs[d]}\n\nQuestion: {_QUESTIONS[i % len(_QUESTIONS)]}"
            for i, d in enumerate(order)
        ]
    if scenario == "mixed":
        out = []
        for i in range(n):
            if i % 3 == 0:
                # A long prompt with a unique preamble, so no two long prompts share a
                # prefix and the prefix scorer has nothing useful to say.
                nonce = f"[request {rng.randrange(10**9)}] "
                out.append(
                    nonce
                    + _document(_DOC_A_SEED if i % 2 else _DOC_B_SEED, doc_tokens)
                    + f"\n\nQuestion: {_QUESTIONS[i % len(_QUESTIONS)]}"
                )
            else:
                out.append(_SHORT_PROMPTS[i % len(_SHORT_PROMPTS)])
        return out
    if scenario == "skew":
        return [_SHORT_PROMPTS[i % len(_SHORT_PROMPTS)] for i in range(n)]
    raise SystemExit(f"unknown scenario {scenario!r}")


def background_load(
    replica: str,
    model: str,
    stop: threading.Event,
    concurrency: int,
    max_tokens: int,
) -> None:
    """Keep one replica busy, dialled directly, not through the gateway.

    The point is that the gateway is never told this is happening. Nothing sets a
    header, nothing drains an endpoint, nothing is marked unhealthy: the replica is
    simply busy, and the only way to know is to read its metrics. That is the situation
    a scheduler has to cope with in real life, where the other traffic is a batch job,
    another team, or a retry storm.
    """
    base = f"http://{replica}"

    def worker() -> None:
        while not stop.is_set():
            chat(base, model, _document(_DOC_A_SEED, 1500), max_tokens, timeout=300)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(concurrency)]
    for t in threads:
        t.start()
    stop.wait()


# ── main ─────────────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario", choices=["mixed", "prefix", "skew"])
    ap.add_argument("--label", default="", help="printed in the header, e.g. the profile under test")
    ap.add_argument("--base-url", default=os.environ.get("GATEWAY_URL", "http://inference-gateway.models.svc.cluster.local"))
    ap.add_argument("--model", default=os.environ.get("MODEL_NAME", "qwen3-coder-30b"))
    ap.add_argument("--requests", type=int, default=48)
    ap.add_argument("--concurrency", type=int, default=12)
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--doc-tokens", type=int, default=3000)
    ap.add_argument(
        "--docs",
        type=int,
        default=2,
        help="how many distinct documents the prefix scenario cycles through. This is "
             "the knob that decides whether the scenario can demonstrate anything: the "
             "working set is roughly docs x doc-tokens, and if that fits in the model "
             "server's KV cache then nothing is ever evicted, every replica ends up "
             "holding everything, and a cache-aware scheduler wins nothing because "
             "locality was free. Size it against the server's actual cache.",
    )
    ap.add_argument("--warmup", type=int, default=4, help="unmeasured requests sent first")
    ap.add_argument(
        "--replicas",
        default=os.environ.get(
            "REPLICAS",
            "vllm-0.vllm-headless.models.svc.cluster.local:8000,"
            "vllm-1.vllm-headless.models.svc.cluster.local:8000",
        ),
        help="comma separated host:port of each model server, scraped for /metrics",
    )
    ap.add_argument("--skew-concurrency", type=int, default=8)
    ap.add_argument("--json", action="store_true", help="emit machine readable output as well")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument(
        "--shuffle",
        action="store_true",
        help="randomise the order documents are requested in. Without it the corpus is "
             "walked in a cycle, and a scheduler that assigns requests in runs gets a "
             "run of consecutive documents, which flatters it for a reason that has "
             "nothing to do with caching. Use it for any comparison you intend to "
             "believe.",
    )
    ap.add_argument(
        "--doc-nonce",
        default="",
        help="prepended to the prefix scenario's documents. Comparing two schedulers on "
             "the SAME documents is invalid after the first run: both replicas have "
             "cached them, both report ~100%% hits, and the difference you were trying "
             "to measure has already happened. Pass a fresh value per comparison so both "
             "arms start cold, and the same value within one comparison.",
    )
    args = ap.parse_args()

    replicas = [r.strip() for r in args.replicas.split(",") if r.strip()]
    rng = random.Random(args.seed)

    print(f"scenario   {args.scenario}{'  (' + args.label + ')' if args.label else ''}")
    print(f"gateway    {args.base_url}")
    print(f"load       {args.requests} requests, {args.concurrency} concurrent, max_tokens={args.max_tokens}")
    if args.scenario == "prefix":
        print(f"corpus     {args.docs} documents x ~{args.doc_tokens} tokens "
              f"= ~{args.docs * args.doc_tokens:,} tokens of working set")
    print(f"replicas   {', '.join(replicas)}")
    print()

    # Warm up before the before-scrape, not after. A cold replica pays for CUDA graph
    # selection and a first-touch of the weights on its first few requests, and folding
    # that into the measured window makes whichever profile ran first look worst.
    if args.warmup:
        warm = build_prompts(
            args.scenario, args.warmup, args.doc_tokens, random.Random(args.seed + 1),
            args.doc_nonce, args.docs, args.shuffle,
        )
        with ThreadPoolExecutor(max_workers=min(args.warmup, args.concurrency)) as ex:
            list(ex.map(lambda p: chat(args.base_url, args.model, p, 16, 300), warm))
        print(f"warmed up with {args.warmup} requests")

    stop = threading.Event()
    bg: threading.Thread | None = None
    if args.scenario == "skew":
        target = replicas[0]
        print(f"background load direct to {target} ({args.skew_concurrency} concurrent, not via the gateway)")
        bg = threading.Thread(
            target=background_load,
            args=(target, args.model, stop, args.skew_concurrency, 512),
            daemon=True,
        )
        bg.start()
        # Let the queue actually build before measuring. The Endpoint Picker scrapes on
        # an interval, so a measurement that starts immediately is measuring a scheduler
        # working from stale gauges, which is a real effect but not the one under test.
        time.sleep(20)

    before = {r: scrape(r) for r in replicas}
    prompts = build_prompts(
        args.scenario, args.requests, args.doc_tokens, rng, args.doc_nonce, args.docs,
        args.shuffle,
    )

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        results = list(ex.map(lambda p: chat(args.base_url, args.model, p, args.max_tokens, 300), prompts))
    wall = time.perf_counter() - t0

    if bg is not None:
        stop.set()
        # Give the background requests a moment to finish so the after-scrape is not
        # counting half a request.
        time.sleep(3)

    after = {r: scrape(r) for r in replicas}

    ok = [r for r in results if r.ok]
    bad = [r for r in results if not r.ok]

    print()
    print(f"{'':<14}{'p50':>9}{'p95':>9}")
    print(f"{'ttft (s)':<14}{pct([r.ttft for r in ok], 50):>9.2f}{pct([r.ttft for r in ok], 95):>9.2f}")
    print(f"{'total (s)':<14}{pct([r.total for r in ok], 50):>9.2f}{pct([r.total for r in ok], 95):>9.2f}")
    print()
    print(f"completed   {len(ok)}/{len(results)} in {wall:.1f}s  ({len(ok)/wall:.2f} req/s)")
    if ok:
        print(f"mean ttft   {statistics.fmean(r.ttft for r in ok):.2f}s")
    if bad:
        print(f"failed      {len(bad)}  first error: {bad[0].error}")

    print()
    print(f"{'replica':<40}{'served':>8}{'prompt tok':>12}{'cached':>12}{'prefix hit':>12}")
    served_counts = []
    for r in replicas:
        b, a = before[r], after[r]
        served = a.finished - b.finished
        served_counts.append(served)
        ptok = a.prompt_tokens - b.prompt_tokens
        q = a.prefix_queries - b.prefix_queries
        h = a.prefix_hits - b.prefix_hits
        rate = f"{100.0 * h / q:.0f}%" if q > 0 else "n/a"
        cached = a.prompt_tokens_cached - b.prompt_tokens_cached
        short = r.split(".")[0]
        print(f"{short:<40}{served:>8.0f}{ptok:>12.0f}{cached:>12.0f}{rate:>12}")

    total_served = sum(served_counts) or 1
    spread = max(served_counts) / total_served * 100
    print()
    print(f"split       {' / '.join(f'{s/total_served*100:.0f}%' for s in served_counts)}"
          f"   (busiest replica took {spread:.0f}%)")
    # prompt tokens processed is the honest cost signal: two replicas that each prefill
    # the same document have done the work twice, and that shows up here even when the
    # request split looks even.
    tok = [after[r].prompt_tokens - before[r].prompt_tokens for r in replicas]
    print(f"prompt tokens prefetched across the pool: {sum(tok):.0f}")

    if args.json:
        print()
        print("JSON " + json.dumps({
            "scenario": args.scenario,
            "label": args.label,
            "requests": len(results),
            "ok": len(ok),
            "wall_s": round(wall, 3),
            "ttft_p50": round(pct([r.ttft for r in ok], 50), 4),
            "ttft_p95": round(pct([r.ttft for r in ok], 95), 4),
            "total_p50": round(pct([r.total for r in ok], 50), 4),
            "total_p95": round(pct([r.total for r in ok], 95), 4),
            "replicas": {
                r: {
                    "served": after[r].finished - before[r].finished,
                    "prompt_tokens": after[r].prompt_tokens - before[r].prompt_tokens,
                    "prompt_tokens_cached": after[r].prompt_tokens_cached - before[r].prompt_tokens_cached,
                    "prefix_queries": after[r].prefix_queries - before[r].prefix_queries,
                    "prefix_hits": after[r].prefix_hits - before[r].prefix_hits,
                }
                for r in replicas
            },
        }))

    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
