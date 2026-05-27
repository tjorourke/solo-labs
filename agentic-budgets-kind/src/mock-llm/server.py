"""mock-llm — OpenAI-compatible /v1/chat/completions stand-in.

This service exists so the demo costs nothing to rehearse. It accepts a
standard OpenAI chat-completions request and returns a canned essay-shaped
response with a realistic `usage` field:

    {
      "prompt_tokens":     <roughly len(words in input) * 1.3>,
      "completion_tokens": <randomized 400..1500>,
      "total_tokens":      prompt_tokens + completion_tokens
    }

The point of the `usage` field is so agentgateway's TOKEN-type rate limit
counter (configured in yaml/agentgateway/ratelimit-config.yaml) has
something to read on the way back. The gateway's `entRateLimit` knows how
to parse OpenAI-format `usage.*_tokens` fields out of the response body and
debit them against the matched descriptor bucket.

No real LLM calls. No external dependencies beyond Starlette + uvicorn.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import re
import time
import uuid

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("mock-llm")


# ── Canned essay-style completions ───────────────────────────────────────────
# Each template is a small fixed-cost essay. The "completion_tokens" field
# below is randomized independently — it doesn't have to match the prose
# length, since the rate limiter only reads what we tell it.
TEMPLATES: list[str] = [
    (
        "The history of database administration spans several decades, beginning "
        "with hierarchical models on mainframes and evolving through the relational "
        "revolution of the 1970s, the rise of distributed systems in the 1990s, "
        "and the cloud-native NoSQL and NewSQL waves of the 2010s. Each era "
        "introduced its own discipline of capacity planning, backup, recovery, "
        "and performance tuning. Today, a database administrator sits at the "
        "intersection of storage, networking, security, and developer experience, "
        "and the role has grown to include observability, cost governance, and "
        "automation of every routine task that used to require a midnight pager."
    ),
    (
        "Indexes are deceptively expensive. They speed up reads but slow down "
        "writes, and every additional index multiplies the cost of an insert "
        "or update. The mature DBA learns to view each index as a contract: it "
        "promises performance for a defined query shape in exchange for "
        "consuming storage, write throughput, and memory. Adding indexes "
        "without removing unused ones is a slow leak that surfaces only under "
        "load. A periodic review of pg_stat_user_indexes (or its equivalent) "
        "is a cheap exercise that pays for itself many times over."
    ),
    (
        "When a customer support team designs a triage process, the most "
        "important question is rarely 'how do we answer faster' — it is 'how "
        "do we route a ticket to the right person on the first attempt'. "
        "Misrouting is the largest hidden cost in support: it inflates "
        "time-to-resolution, fragments customer context across queues, and "
        "erodes trust. A well-tuned routing model — be it skill-based, "
        "topic-classifier-driven, or a hybrid — outperforms simply hiring "
        "more first-line agents."
    ),
    (
        "Backups are not for disasters. They are for the small, routine "
        "mistakes — a dropped table, a botched migration, an over-eager "
        "ALTER statement. The discipline of a good DBA is to design backup "
        "and recovery for the failures you have seen before, not the "
        "catastrophic ones you read about. Point-in-time recovery in "
        "particular is the single most-used tool, and the one most often "
        "skipped in tests. Verify it on a recurring cadence — at least "
        "monthly — and verify it end-to-end, not just that the WAL files "
        "exist."
    ),
    (
        "A long essay on the topic of query plans would begin with the "
        "observation that every database query is a question the planner "
        "must translate into a sequence of physical operations. Each "
        "operation has a cost — measured in I/O, CPU, and memory — and the "
        "planner's job is to find the cheapest sequence that produces the "
        "correct answer. EXPLAIN ANALYZE is the DBA's microscope: it shows "
        "the plan the planner chose, the cost it estimated, and the actual "
        "cost incurred at runtime. Discrepancies between estimate and actual "
        "are the first place to look when a query regresses."
    ),
    (
        "Customer-support metrics are easy to game. First-response time can "
        "be reduced by auto-replying with a placeholder. Resolution rate "
        "can be padded by closing tickets prematurely. Customer satisfaction "
        "scores can be inflated by asking for feedback only after good "
        "interactions. The metrics that actually correlate with retention "
        "are usually the ones that resist gaming: time-to-correct-routing, "
        "rate of customers who self-resolve via documentation, and the "
        "fraction of escalations that surface a previously-unknown product "
        "issue."
    ),
    (
        "Schema migrations are the highest-risk operation a DBA performs. "
        "An ALTER TABLE on a hot table can lock readers for minutes and "
        "writers for hours. The modern playbook is to break each migration "
        "into a sequence of safe steps: add the new column nullable, "
        "backfill in batches, switch the application to dual-write, then "
        "drop the old column once traffic has migrated. Each step is "
        "individually reversible; together they get you to the new shape "
        "without ever holding a long lock."
    ),
    (
        "Observability for a database is harder than for a stateless "
        "service. Metrics like CPU and memory are easy to graph but "
        "tell you very little about the workload. The metrics that "
        "matter — query latency by percentile, lock-wait time, replication "
        "lag, buffer-cache hit ratio — require deliberate instrumentation. "
        "The discipline is to define the dashboards you will look at "
        "during the next incident, then verify they answer the questions "
        "you actually ask during one."
    ),
    (
        "Triaging a flood of support tickets is a search problem. The "
        "incoming pile has shape: most tickets cluster around a small "
        "number of root causes, and the routing model that recognises "
        "those clusters early can drain the queue much faster than one "
        "that treats every ticket as unique. The hard part is keeping "
        "the cluster definitions current — yesterday's product release "
        "may have killed a whole class of tickets and spawned a new one."
    ),
    (
        "Cost governance for LLM workloads is in many ways analogous to "
        "the cost governance of cloud compute a decade ago. The unit "
        "(tokens vs. CPU-seconds) is different, but the failure modes "
        "are familiar: unbounded usage by a runaway loop, drift from a "
        "small per-call cost to a large monthly invoice, and the need "
        "for per-team accountability so that one team's incident doesn't "
        "exhaust a shared budget. A gateway that meters tokens at the "
        "edge — like the one fronting this very server — is the equivalent "
        "of the cost-management dashboards that became standard practice "
        "for cloud compute."
    ),
]


# ── Token estimator ───────────────────────────────────────────────────────────
def _approx_prompt_tokens(messages: list[dict]) -> int:
    """Crude word-count × 1.3 estimator.

    Real tokenizers (tiktoken, etc.) would give exact counts but require
    pulling several MB of vocab files. For a mock service the estimate is
    fine — and matches the order of magnitude real LLMs produce.
    """
    words = 0
    for m in messages:
        content = m.get("content", "")
        if isinstance(content, list):  # OpenAI vision-style content lists
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    words += len(re.findall(r"\S+", c.get("text", "")))
        else:
            words += len(re.findall(r"\S+", str(content)))
    return max(1, int(words * 1.3))


# ── Handler ───────────────────────────────────────────────────────────────────
async def chat_completions(request: Request) -> JSONResponse:
    """OpenAI-compatible /v1/chat/completions."""
    # Log a small subset of incoming request headers so we can confirm
    # gateway-side projections like X-Team-ID actually arrive.
    log_hdrs = {
        k: v for k, v in request.headers.items()
        if k.lower() in ("x-team-id", "x-user-id", "x-forwarded-for", "user-agent")
    }
    logger.info("incoming headers: %s", log_hdrs)
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        return JSONResponse({"error": {"message": "invalid JSON body"}}, status_code=400)

    messages = body.get("messages") or []
    model = body.get("model") or "mock-essay-7b"

    # Simulate inference latency.
    await asyncio.sleep(random.uniform(0.2, 0.5))

    completion_text = random.choice(TEMPLATES)
    prompt_tokens = _approx_prompt_tokens(messages)
    # Variable per the lab spec — 400..1500 completion tokens.
    completion_tokens = random.randint(400, 1500)
    total_tokens = prompt_tokens + completion_tokens

    response = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": completion_text,
                },
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total_tokens,
        },
    }
    logger.info(
        "served chat.completion model=%s prompt_tokens=%d completion_tokens=%d total=%d",
        model, prompt_tokens, completion_tokens, total_tokens,
    )
    return JSONResponse(response)


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


async def models(_: Request) -> JSONResponse:
    """Optional /v1/models so curl --list-models doesn't error."""
    return JSONResponse({
        "object": "list",
        "data": [{"id": "mock-essay-7b", "object": "model", "owned_by": "mock-llm"}],
    })


routes = [
    Route("/v1/chat/completions", chat_completions, methods=["POST"]),
    Route("/v1/models", models, methods=["GET"]),
    Route("/healthz", healthz, methods=["GET"]),
]
app = Starlette(routes=routes)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
