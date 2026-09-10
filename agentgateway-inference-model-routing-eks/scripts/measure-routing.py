#!/usr/bin/env python3
"""Time streaming requests from inside the cluster; select the routing policy first.

kubectl -n models exec -i deploy/vllm -c vllm -- \
  python3 - explicit --samples 10 < scripts/measure-routing.py

The mode labels the run and chooses a concrete model or auto. It does not change or
inspect the gateway policy. See the lab's timing section for the mode-switch commands.
"""

import argparse
import datetime
import json
import statistics
import sys
import time
import urllib.request
import uuid


URL = "http://model-gateway.agentgateway-system.svc.cluster.local/v1/chat/completions"
CASES = [
    ("finance", "mistral-small-3.2-24b", "What is IFRS 9 stage 2 impairment?"),
    ("coding", "qwen3-coder-30b", "Write a Python function that reverses a linked list."),
]


def measure(url, requested, expected, prompt):
    request_id = str(uuid.uuid4())
    body = {
        "model": requested,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 64,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-request-id": request_id},
    )
    start = time.perf_counter()
    first_content = None
    models = set()
    output_tokens = None
    complete = False
    with urllib.request.urlopen(request, timeout=180) as response:
        if "text/event-stream" not in response.headers.get("Content-Type", ""):
            raise ValueError("expected a streaming response, not JSON or an error page")
        for line in response:
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                complete = True
                break
            event = json.loads(data)
            if event.get("error"):
                raise ValueError(f"stream error: {event['error']}")
            if event.get("model"):
                models.add(event["model"])
            if event.get("usage"):
                output_tokens = event["usage"].get("completion_tokens")
            # A role-only event or response headers are not a generated text token.
            if first_content is None and any(
                choice.get("delta", {}).get("content") for choice in event.get("choices", [])
            ):
                first_content = time.perf_counter()
        end = time.perf_counter()
    if not complete or first_content is None:
        raise ValueError("stream ended without [DONE] or without any text content")
    if models != {expected}:
        raise ValueError(f"expected {expected}, response reported {sorted(models)}")
    return {
        "request_id": request_id,
        "model": expected,
        "ttft_ms": round((first_content - start) * 1000, 2),
        "total_ms": round((end - start) * 1000, 2),
        "output_tokens": output_tokens,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["explicit", "keyword", "semantic"])
    parser.add_argument("--samples", type=int, default=10)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be at least 1")
    print(json.dumps({
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "mode": args.mode, "samples_per_prompt": args.samples,
        "warmups_per_prompt": 2, "concurrency": 1,
        "max_tokens": 64, "temperature": 0, "url": URL,
    }), flush=True)
    summaries = []
    for name, model, prompt in CASES:
        requested = model if args.mode == "explicit" else "auto"
        for _ in range(2):
            measure(URL, requested, model, prompt)
        results = []
        for sample in range(1, args.samples + 1):
            result = measure(URL, requested, model, prompt)
            results.append(result)
            print(json.dumps({"prompt": prompt, "sample": sample, **result}), flush=True)
        summaries.append((name, model, results))
    print("\nMODE      PROMPT   RESPONSE MODEL          N    TTFT p50 ms  TOTAL p50 ms")
    for name, model, results in summaries:
        ttft = statistics.median(r["ttft_ms"] for r in results)
        total = statistics.median(r["total_ms"] for r in results)
        print(f"{args.mode:9} {name:8} {model:23} {len(results):3} {ttft:12.2f} {total:13.2f}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f"measurement failed: {error}")
