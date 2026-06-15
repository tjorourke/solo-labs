"""A2A executor for the AutoGen crew.

kagent ships first-class adapters for ADK, LangGraph and CrewAI. Any other
framework runs as a BYO agent by serving the A2A protocol on :8080, which the
kagent controller proxies to. This is that shim for AutoGen: a small AgentExecutor
that runs the team and reports the result over A2A. It uses an in-memory task store
(self-contained), so there are no session callbacks to the controller.
"""
from __future__ import annotations

import logging

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.utils import new_agent_text_message

from team import build_team

logger = logging.getLogger(__name__)


class AutogenExecutor(AgentExecutor):
    """Runs the AutoGen team for one A2A request and reports the final message."""

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        await updater.submit()
        await updater.start_work()

        user_text = context.get_user_input()
        logger.info("autogen crew running for task: %s", user_text)

        team = await build_team()
        result = await team.run(task=user_text)

        # The last message in the conversation is the operator's summary.
        final = ""
        if result.messages:
            content = result.messages[-1].content
            final = content if isinstance(content, str) else str(content)
        await updater.complete(
            new_agent_text_message(final or "(no output)", context.context_id, context.task_id)
        )

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("cancel is not supported")
