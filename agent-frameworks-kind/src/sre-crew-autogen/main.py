"""Entrypoint — serve the AutoGen crew as a BYO kagent A2A agent on :8080.

Builds the A2A app directly from the a2a-sdk (the contract every kagent BYO agent
must serve), with an in-memory task store and the AutoGen executor.
"""
import json
import logging
import os

import uvicorn
from a2a.server.apps import A2AFastAPIApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCard

from executor import AutogenExecutor

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)


def main() -> None:
    with open(os.path.join(os.path.dirname(__file__), "agent-card.json"), "r") as f:
        agent_card = AgentCard.model_validate(json.load(f))

    handler = DefaultRequestHandler(
        agent_executor=AutogenExecutor(),
        task_store=InMemoryTaskStore(),
    )
    a2a_app = A2AFastAPIApplication(agent_card=agent_card, http_handler=handler)
    app = a2a_app.build()

    port = int(os.getenv("PORT", "8080"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info("starting BYO A2A server (AutoGen) on %s:%d", host, port)
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
