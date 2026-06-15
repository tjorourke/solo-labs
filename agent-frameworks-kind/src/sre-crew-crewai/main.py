"""Entrypoint — serve the CrewAI crew as a kagent A2A agent on :8080.

Mirrors python/samples/crewai/research-crew/src/research_crew/main.py from
kagent-dev/kagent: kagent.crewai.KAgentApp wraps the Crew, builds the FastAPI app,
uvicorn serves it.
"""
import json
import logging
import os

import uvicorn
from kagent.crewai import KAgentApp

from crew import build_crew

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)


def main() -> None:
    with open(os.path.join(os.path.dirname(__file__), "agent-card.json"), "r") as f:
        agent_card = json.load(f)
    app = KAgentApp(crew=build_crew(), agent_card=agent_card)
    server = app.build()
    port = int(os.getenv("PORT", "8080"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info("starting kagent A2A server on %s:%d", host, port)
    uvicorn.run(server, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
