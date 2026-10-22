"""Keep the native ADK ledger's Enterprise callbacks scoped to the caller."""
from contextvars import ContextVar

from kagent.adk._a2a import KAgentApp
from kagent.adk._token import KAgentTokenService

user = ContextVar("bank_callback_user", default=None)


class CallbackUserContext:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        token = user.set(headers.get(b"x-user-id", b"").decode() or None)
        try:
            await self.app(scope, receive, send)
        finally:
            user.reset(token)


_build = KAgentApp.build
_hooks = KAgentTokenService.event_hooks


def build(self, *args, **kwargs):
    app = _build(self, *args, **kwargs)
    app.add_middleware(CallbackUserContext)
    return app


async def add_user(request):
    if user_id := user.get():
        request.url = request.url.copy_set_param("user_id", user_id)


def hooks(self):
    value = _hooks(self)
    value.setdefault("request", []).append(add_user)
    return value


KAgentApp.build = build
KAgentTokenService.event_hooks = hooks
