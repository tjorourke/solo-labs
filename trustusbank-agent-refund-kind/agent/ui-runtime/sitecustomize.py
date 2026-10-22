"""kagent Python runtime compatibility: scope task reads to the UI user.

The upstream request-context builder runs after TaskManager.get_task(). Set
the same context at ASGI entry so approval resumes can read their own task.
Keep the context request-local and restore it even on disconnect or failure.
This does not change controller authentication or task ownership checks.
"""

from types import MethodType

from kagent.adk._a2a import KAgentApp
from kagent.adk._mcp_toolset import KAgentMcpToolset
from kagent.adk._token import KAgentTokenService
from kagent.core.a2a._context import get_request_user_id, set_request_user_id


class ForwardedUserContext:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        previous = get_request_user_id()
        headers = dict(scope.get("headers", []))
        user_id = headers.get(b"x-user-id", b"").decode("utf-8") or None
        set_request_user_id(user_id)
        try:
            await self.app(scope, receive, send)
        finally:
            set_request_user_id(previous)


_build = KAgentApp.build


def build_with_user_context(self, *args, **kwargs):
    app = _build(self, *args, **kwargs)
    app.add_middleware(ForwardedUserContext)
    return app


KAgentApp.build = build_with_user_context

# ADK 1.38 validates check_require_confirmation when resuming a confirmation.
# kagent 0.10.x's requireApproval callback requests confirmation but does not
# implement that method. Retain the callback and mark this lab's tool too.
_get_tools = KAgentMcpToolset.get_tools


async def requires_confirmation(self, args, tool_context):
    return True


async def get_tools_with_confirmation(self, *args, **kwargs):
    tools = await _get_tools(self, *args, **kwargs)
    for tool in tools:
        if tool.name == "approve_delegated_refund":
            tool.check_require_confirmation = MethodType(requires_confirmation, tool)
    return tools


KAgentMcpToolset.get_tools = get_tools_with_confirmation

# Enterprise controllers require the user_id query for service-account callbacks.
_event_hooks = KAgentTokenService.event_hooks


async def add_callback_user(request):
    if user_id := get_request_user_id():
        request.url = request.url.copy_set_param("user_id", user_id)


def event_hooks_with_user(self):
    hooks = _event_hooks(self)
    hooks.setdefault("request", []).append(add_callback_user)
    return hooks


KAgentTokenService.event_hooks = event_hooks_with_user
