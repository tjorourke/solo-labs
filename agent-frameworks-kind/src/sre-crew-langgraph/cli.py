"""Entrypoint — serve the LangGraph crew as a kagent A2A agent on :8080.

Mirrors python/samples/langgraph/currency/currency/cli.py from kagent-dev/kagent:
KAgentApp wraps the compiled graph, builds the A2A FastAPI app, uvicorn serves it.
"""
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
    # tracing on: kagent-core configures OTel (OpenAI/Anthropic/httpx instrumentation)
    # and exports OTLP to OTEL_EXPORTER_OTLP_ENDPOINT, which agentevals scores.
    app = KAgentApp(graph=graph, agent_card=agent_card, config=config, tracing=True)
    port = int(os.getenv("PORT", "8080"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info("starting kagent A2A server on %s:%d", host, port)
    uvicorn.run(app.build(), host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
