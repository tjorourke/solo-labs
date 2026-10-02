import ast
import json
import os
import re
import uuid

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm
from google.adk.models.llm_response import LlmResponse
from google.genai import types

from .mcp_tools import get_mcp_tools

os.environ.setdefault("OTEL_SERVICE_NAME", "trustusbank-agents")


# Tracing is kagent's: kagent-core reads the OTLP env AgentRegistry injects and
# exports over gRPC to the Solo collector. ADK's maybe_set_otel_providers() would add
# a second, HTTP exporter that fails on that gRPC-only port on every span.

class GemmaLiteLlm(LiteLlm):
    async def generate_content_async(self, llm_request, stream=False):
        # vLLM 0.8.5's pythonic streaming parser can emit no final response for
        # quoted/fenced tool calls. Parse the complete tool response instead;
        # the A2A stream still carries tool events and the final answer.
        async for response in super().generate_content_async(llm_request, stream=False):
            yield response


def create_model():
    """The company gateway when MODEL_BASE_URL is set, otherwise straight to the provider.

    Through the gateway the model is addressed as openai/<name>, because the gateway reads
    identity from an Authorization: Bearer header and that is the shape LiteLLM sends it on.
    The Anthropic shape sends x-api-key, which the gateway does not read, so the request
    arrives with no subject and is refused. MODEL_API_KEY is the agent's own JWT, not a
    provider key: the gateway decides the model from the prompt and the subject.
    """
    model = os.environ.get("MODEL_NAME") or "gemma-3-27b-it"
    base = os.environ.get("MODEL_BASE_URL")
    if base:
        return GemmaLiteLlm(
            model="openai/" + model.split("/", 1)[-1],
            api_base=base,
            api_key=os.environ.get("MODEL_API_KEY") or "",
        )
    if not model.startswith("anthropic/"):
        model = "anthropic/" + model
    return LiteLlm(model=model, api_key=os.environ.get("ANTHROPIC_API_KEY") or None)


def instruction():
    return os.environ.get("SYSTEM_MESSAGE") or (
        "You are a helpful assistant. Use only the tools you have been given."
    )


def allowed_tools():
    """MCP filter matches the server's own names (list_issues)."""
    raw = os.environ.get("ALLOWED_TOOLS") or ""
    if not raw.strip():
        return None
    try:
        names = json.loads(raw)
    except json.JSONDecodeError:
        names = [t.strip() for t in raw.split(",") if t.strip()]
    out = []
    seen = set()
    for n in names:
        base = n.split(".", 1)[-1]
        if base.startswith("github_"):
            base = base[len("github_"):]
        for alias in (n, base):
            if alias and alias not in seen:
                seen.add(alias)
                out.append(alias)
    return out or None


_TEXT_CALLS = re.compile(r"(?:^|\n)\s*(?:```(?:python|tool_code|py)?\s*)?(\[.*\])\s*(?:```)?\s*$", re.S)


def _call(node):
    """A keyword-only call node as a function_call part, or None."""
    # Gemma sometimes quotes each call: ["get_x(a=1)"]. Unwrap the string.
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        node = ast.parse(node.value.strip(), mode="eval").body
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)) or node.args:
        return None
    args = {kw.arg: ast.literal_eval(kw.value) for kw in node.keywords}
    # Not "adk-": ADK strips ids with that prefix before replaying history,
    # and vLLM rejects a tool call whose id is null.
    return types.Part(function_call=types.FunctionCall(
        id="call_" + uuid.uuid4().hex, name=node.func.id, args=args))


def text_tool_calls(callback_context, llm_response):
    """Recover a tool call Gemma wrote in a shape vLLM's parser cannot read.

    The pythonic parser only reads a bare [get_x(a=1)]. Gemma also answers with
    the list in a ```python fence, or with each call quoted, ["get_x(a=1)"]; both
    come back as plain text and the agent would print the call instead of running
    it, or end the turn with nothing. Turn those into real function calls; anything
    that is not a clean list of keyword calls is left alone.
    """
    content = llm_response.content
    if llm_response.partial or not content or not content.parts:
        return None
    if any(p.function_call for p in content.parts):
        return None
    m = _TEXT_CALLS.search("".join(p.text or "" for p in content.parts))
    if not m:
        return None
    try:
        tree = ast.parse(m.group(1), mode="eval").body
        if not isinstance(tree, ast.List) or not tree.elts:
            return None
        calls = [_call(node) for node in tree.elts]
    except (SyntaxError, ValueError):
        return None
    if not all(calls):
        return None
    return LlmResponse(content=types.Content(role="model", parts=calls))


# One toolset, unprefixed. Gemma 3 has an 8k context and the tool list rides in
# the prompt, so the console runtime's second, prefixed copy of every tool would
# halve the room left for the conversation.
_filter = allowed_tools()
mcp_tools = get_mcp_tools(global_filter=_filter, prefix=False)
root_agent = Agent(
    model=create_model(),
    # The name kagent's traces show for every span. One image serves all four
    # agents, so it comes from the Deployment (agents.json agent_name). Not
    # AGENT_NAME: AgentRegistry sets that to the hyphenated record name, which
    # ADK rejects as an identifier.
    name=re.sub(r"\W", "_", os.environ.get("ADK_AGENT_NAME") or "my_agents_agent"),
    description=os.environ.get("AGENT_DESCRIPTION") or "AgentRegistry agent.",
    instruction=instruction(),
    tools=mcp_tools if mcp_tools else [],
    generate_content_config=types.GenerateContentConfig(temperature=0, max_output_tokens=2048),
    after_model_callback=text_tool_calls,
)
