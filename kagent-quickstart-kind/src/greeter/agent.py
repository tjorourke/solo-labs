"""A minimal BYO Google ADK agent — a friendly greeter. Brought your own: your
code, your ADK graph. The model is Anthropic via LiteLlm, reached directly
(ANTHROPIC_API_KEY in the pod env); no gateway required for this quickstart.
"""
from __future__ import annotations
import os
from google.adk.agents import LlmAgent
from google.adk.models.lite_llm import LiteLlm

MODEL = os.environ.get("MODEL", "claude-haiku-4-5")

root_agent = LlmAgent(
    name="greeter",
    model=LiteLlm(model=f"anthropic/{MODEL}"),   # reads ANTHROPIC_API_KEY from the env
    description="A friendly greeter agent, brought your own with Google ADK.",
    instruction=(
        "You are a warm, concise greeter. Greet the user in one short, friendly "
        "sentence. If they give a name, use it."
    ),
)
