"""CLI entry point — wires the LangGraph graph into kagent's A2A app."""
from __future__ import annotations

import json
import logging
import os

import uvicorn
from agent import graph
from kagent.core import KAgentConfig
from kagent.langgraph import KAgentApp

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)


def main() -> None:
    with open(os.path.join(os.path.dirname(__file__), "agent-card.json"), "r") as f:
        agent_card = json.load(f)
    config = KAgentConfig()
    app = KAgentApp(graph=graph, agent_card=agent_card, config=config, tracing=False)
    port = int(os.getenv("PORT", "8080"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info("starting kagent A2A server on %s:%d", host, port)
    uvicorn.run(app.build(), host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
