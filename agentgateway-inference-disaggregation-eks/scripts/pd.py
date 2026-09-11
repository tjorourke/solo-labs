#!/usr/bin/env python3
"""Measure disaggregated serving, and prove it actually happened.

Standard library only, run from inside the cluster (scripts/bench.sh execs it in the
load-balancing lab's loadgen pod).

WHAT IT MEASURES

Not time to first token. Disaggregation does not make TTFT better and on this hardware
it makes it worse: the prompt goes to one card, the KV blocks come back over TCP because
g7e.2xlarge has no EFA, and only then does generation start. Reporting TTFT as the
headline would be measuring the wrong thing and then being disappointed by it.

What disaggregation is for is the OTHER request. When prefill and decode share one
engine, a long prompt arriving mid-stream takes the GPU for a full forward pass over
thousands of tokens, and every conversation already generating stalls for as long as
that takes. Split them and the long prefill happens on a card that is not generating
anything, so the stall does not happen. The number that shows it is inter-token latency
on the short requests while a long one is in flight.

So: one long background request, several short measured ones alongside it, and the gaps
between their tokens.

HOW IT PROVES DISAGGREGATION HAPPENED

By the shape of each pod's counters, which cannot be faked by a 200 response:

  disaggregated     prefill does the prompt tokens and generates ~1 token per request
                    decode does ~no prompt tokens and all the generation
  monolithic        decode does both; prefill's counters do not move at all

A run that reports itself disaggregated while the prefill pod's prompt_tokens_total is
flat did not disaggregate, whatever anything else says.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

_DOC_SEED = (
    "INCIDENT TIMELINE: the settlement batch ran long on the night of the change, and "
    "the read model fell behind the write model by a margin large enough that the "
    "morning reconciliation reported gaps that were not gaps. Each entry below records "
    "an observation, the time it was made, the person who made it and what they "
    "believed at the time, which is not always what turned out to be true. "
)


def document(approx_tokens: int, nonce: str = "") -> str:
    """Roughly approx_tokens of prose, optionally with a unique opening.

    Four characters per token, the same rough conversion the scheduler's prefix plugin
    uses on untokenised text. The nonce matters: without it, the second long request
    shares its whole prefix with the first, the decider sees nothing uncached and runs
    it monolithic, and the lab measures a mode it did not intend to be in.
    """
    target = approx_tokens * 4
    out: list[str] = []
    n = 0
    i = 0
    if nonce:
        out.append(f"[{nonce}] ")
        n += len(out[0])
    while n < target:
        para = f"[entry {i}] {_DOC_SEED}"
        out.append(para)
        n += len(para)
        i += 1
    return "".join(out)


# ── metrics ──────────────────────────────────────────────────────────────────────────
@dataclass
class Counters:
    finished: float = 0.0
    prompt_tokens: float = 0.0
    generation_tokens: float = 0.0
    waiting: float = 0.0
    running: float = 0.0


_SERIES = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9eE.+-]+)$")
_SUMS = {
    "vllm:request_success_total": "finished",
    "vllm:prompt_tokens_total": "prompt_tokens",
    "vllm:generation_tokens_total": "generation_tokens",
}
_GAUGES = {
    "vllm:num_requests_waiting": "waiting",
    "vllm:num_requests_running": "running",
}


def scrape(host: str, timeout: float = 5.0) -> Counters:
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
        if (k := _SUMS.get(name)) is not None:
            setattr(c, k, getattr(c, k) + v)
        elif (k := _GAUGES.get(name)) is not None:
            setattr(c, k, v)
    return c


# ── one request ──────────────────────────────────────────────────────────────────────
@dataclass
class Result:
    ok: bool
    ttft: float = 0.0
    total: float = 0.0
    gaps: list[float] = field(default_factory=list)
    tokens: int = 0
    error: str = ""


def chat(base_url: str, model: str, prompt: str, max_tokens: int, timeout: float) -> Result:
    """A streaming completion, timing the gap between every pair of content chunks.

    The gaps are the measurement. One chunk is not always one token, so treat these as
    inter-chunk latency: comparable between runs of this script, not comparable with
    vLLM's own vllm:inter_token_latency_seconds histogram.
    """
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
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
    last = 0.0
    gaps: list[float] = []
    tokens = 0
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
                    tokens = usage.get("completion_tokens", 0) or 0
                for ch in obj.get("choices") or []:
                    piece = (ch.get("delta") or {}).get("content")
                    if not piece:
                        # The first chunk of a stream usually carries only the role.
                        # Timing off it overstates how fast the model was.
                        continue
                    now = time.perf_counter()
                    if not ttft:
                        ttft = now - started
                    else:
                        gaps.append(now - last)
                    last = now
    except urllib.error.HTTPError as e:
        return Result(ok=False, error=f"HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")
    except Exception as e:  # noqa: BLE001
        return Result(ok=False, error=f"{type(e).__name__}: {e}")
    return Result(ok=True, ttft=ttft or (time.perf_counter() - started),
                  total=time.perf_counter() - started, gaps=gaps, tokens=tokens)


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    k = max(0, min(len(s) - 1, int(round(p / 100.0 * len(s) + 0.5)) - 1))
    return s[k]


# ── main ─────────────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="", help="printed in the header, e.g. 'disagg on'")
    ap.add_argument("--base-url", default=os.environ.get("GATEWAY_URL", "http://inference-gateway.models.svc.cluster.local"))
    ap.add_argument("--model", default=os.environ.get("MODEL_NAME", "qwen3-coder-30b"))
    ap.add_argument("--short-requests", type=int, default=12, help="the measured, interactive ones")
    ap.add_argument("--short-concurrency", type=int, default=4)
    ap.add_argument("--short-max-tokens", type=int, default=128)
    ap.add_argument("--long-tokens", type=int, default=12000, help="prompt length of the background request")
    ap.add_argument("--long-count", type=int, default=3, help="how many long requests run alongside")
    ap.add_argument(
        "--replicas",
        default=os.environ.get(
            "PD_REPLICAS",
            "vllm-prefill.models.svc.cluster.local:8000,vllm-decode.models.svc.cluster.local:8000",
        ),
        help="comma separated host:port, prefill first",
    )
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    replicas = [r.strip() for r in args.replicas.split(",") if r.strip()]

    print(f"run        {args.label or 'unlabelled'}")
    print(f"gateway    {args.base_url}")
    print(f"load       {args.long_count} x {args.long_tokens}-token prompts in the background,")
    print(f"           {args.short_requests} short requests measured alongside ({args.short_concurrency} concurrent)")
    print()

    # Warm up first, and warm up with a LONG prompt. The first request between a given
    # prefill and decode pair pays a NIXL handshake of a few seconds, once per pair. Fold
    # that into the measured window and the first disaggregated run looks terrible for a
    # reason that has nothing to do with disaggregation.
    if args.warmup:
        for i in range(args.warmup):
            r = chat(args.base_url, args.model, document(args.long_tokens, f"warm-{i}"), 8, 600)
            if not r.ok:
                print(f"warmup failed: {r.error}")
                return 1
        print(f"warmed up with {args.warmup} long requests (NIXL pairing handshake is paid here)")

    before = {r: scrape(r) for r in replicas}

    stop = threading.Event()
    long_results: list[Result] = []

    def long_loop() -> None:
        i = 0
        while not stop.is_set():
            # A fresh nonce every time, so each long prompt really is uncached and the
            # decider keeps choosing to disaggregate it.
            long_results.append(
                chat(args.base_url, args.model, document(args.long_tokens, f"bg-{i}-{time.time()}"), 200, 600)
            )
            i += 1

    bg = [threading.Thread(target=long_loop, daemon=True) for _ in range(args.long_count)]
    for t in bg:
        t.start()
    # Let the long prompts actually be in flight before the short ones start. Without
    # this the short requests finish during the ramp and measure an idle cluster.
    time.sleep(10)

    shorts = [
        "In one sentence, what is a readiness probe for?",
        "Name two reasons a retry can be unsafe.",
        "What does queue depth tell you that CPU utilisation does not?",
        "Give a one-line definition of tail latency.",
    ]
    prompts = [shorts[i % len(shorts)] for i in range(args.short_requests)]

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.short_concurrency) as ex:
        results = list(
            ex.map(lambda p: chat(args.base_url, args.model, p, args.short_max_tokens, 600), prompts)
        )
    wall = time.perf_counter() - t0

    stop.set()
    time.sleep(5)
    after = {r: scrape(r) for r in replicas}

    ok = [r for r in results if r.ok]
    bad = [r for r in results if not r.ok]
    all_gaps = [g for r in ok for g in r.gaps]

    print()
    print("SHORT REQUESTS, measured while the long ones are in flight")
    print(f"{'':<22}{'p50':>9}{'p95':>9}{'max':>9}")
    print(f"{'inter-token gap (ms)':<22}"
          f"{pct(all_gaps, 50) * 1000:>9.0f}{pct(all_gaps, 95) * 1000:>9.0f}"
          f"{(max(all_gaps) if all_gaps else 0) * 1000:>9.0f}")
    print(f"{'ttft (s)':<22}{pct([r.ttft for r in ok], 50):>9.2f}{pct([r.ttft for r in ok], 95):>9.2f}"
          f"{(max((r.ttft for r in ok), default=0)):>9.2f}")
    print()
    print(f"completed   {len(ok)}/{len(results)} short in {wall:.1f}s, {len(long_results)} long finished")
    if all_gaps:
        print(f"mean gap    {statistics.fmean(all_gaps) * 1000:.0f} ms over {len(all_gaps)} samples")
    if bad:
        print(f"failed      {len(bad)}  first error: {bad[0].error}")

    # ── the proof ────────────────────────────────────────────────────────────────────
    print()
    print("WHAT EACH POD DID")
    print(f"{'pod':<16}{'requests':>10}{'prompt tok':>13}{'gen tok':>10}")
    deltas = {}
    for r in replicas:
        b, a = before[r], after[r]
        d = {
            "finished": a.finished - b.finished,
            "prompt": a.prompt_tokens - b.prompt_tokens,
            "gen": a.generation_tokens - b.generation_tokens,
        }
        deltas[r] = d
        print(f"{r.split('.')[0]:<16}{d['finished']:>10.0f}{d['prompt']:>13.0f}{d['gen']:>10.0f}")

    print()
    pre, dec = replicas[0], replicas[-1]
    p_prompt = deltas[pre]["prompt"]
    p_gen = deltas[pre]["gen"]
    d_gen = deltas[dec]["gen"]
    if p_prompt < 1:
        print("VERDICT: monolithic. The prefill pod processed no prompt tokens at all, so")
        print("         every request ran prefill and decode on the decode worker.")
    elif p_gen > 0 and d_gen / max(p_gen, 1) > 5:
        share = 100.0 * p_prompt / max(p_prompt + deltas[dec]["prompt"], 1)
        print(f"VERDICT: disaggregated. The prefill pod took {share:.0f}% of the prompt tokens and")
        print(f"         generated {p_gen:.0f} tokens against the decode pod's {d_gen:.0f}, which is the")
        print("         shape of a worker that prefills and hands off.")
    else:
        print("VERDICT: unclear. Both pods generated a comparable number of tokens, which is")
        print("         neither mode. Check the EPP log for which profiles ran:")
        print("           kubectl -n models logs deploy/pd-epp --tail=40 | grep -i profile")

    if args.json:
        print()
        print("JSON " + json.dumps({
            "label": args.label,
            "short_ok": len(ok),
            "short_total": len(results),
            "long_finished": len(long_results),
            "gap_p50_ms": round(pct(all_gaps, 50) * 1000, 2),
            "gap_p95_ms": round(pct(all_gaps, 95) * 1000, 2),
            "gap_max_ms": round((max(all_gaps) if all_gaps else 0) * 1000, 2),
            "ttft_p50": round(pct([r.ttft for r in ok], 50), 4),
            "pods": {r.split(".")[0]: deltas[r] for r in replicas},
        }))

    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
