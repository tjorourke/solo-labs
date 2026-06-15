"""Entrypoint — serve the ADK crew as a kagent A2A agent on :8080.

Follows the kagent OpenAI/ADK sample pattern: kagent.adk.KAgentApp wraps the root
ADK agent, builds the FastAPI app, uvicorn serves it.
"""
import json
import logging
import os

import uvicorn
from a2a.types import AgentCard
from kagent.adk import KAgentApp
from kagent.core import KAgentConfig

from agent import root_agent

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)


def main() -> None:
    with open(os.path.join(os.path.dirname(__file__), "agent-card.json"), "r") as f:
        # kagent-adk passes the card straight to the a2a-sdk, which needs an
        # AgentCard object (not a raw dict).
        agent_card = AgentCard.model_validate(json.load(f))
    config = KAgentConfig()
    # kagent-adk takes a factory returning the root agent, plus the controller URL
    # and app name (used for session management + token propagation to the controller).
    app = KAgentApp(
        root_agent_factory=lambda: root_agent,
        agent_card=agent_card,
        kagent_url=config.url,
        app_name=config.app_name,
    )
    port = int(os.getenv("PORT", "8080"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info("starting kagent A2A server on %s:%d", host, port)
    uvicorn.run(app.build(), host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
