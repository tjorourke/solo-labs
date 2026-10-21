"""Native ADK confirmation, as used by agentic-verdict-hitl-kind."""
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset, StreamableHTTPConnectionParams
from google.adk.tools.tool_context import ToolContext

INSTRUCTION = """
You are TrustUs Bank's ledger specialist. Use get_payment to check a payment.
Refund only a FAILED payment. If the user requests investigation only, report
the payment and stop. Otherwise call refund_payment for the requested amount,
or the payment's amount when no amount was specified.
Call the tool directly: the ADK confirmation mechanism handles human approval.
Do not ask for permission in text before calling the tool. Never bypass or
retry a refused tool. Return the tool's exact JSON result in your final reply.
"""


def refund_requires_confirmation(payment_id: str, amount_gbp: float, tool_context: ToolContext) -> bool:
    return amount_gbp > 10000


def delegated_headers(context):
    """Exchange the request token using this workload's existing bank identity."""
    if context is None:
        return {}
    headers = context.state.get('headers', {})
    token = headers.get('authorization') or headers.get('Authorization', '')
    subject = token.removeprefix('Bearer ')
    if not subject:
        raise ValueError('Exchanged human token required')
    actor = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
    data = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
        'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt',
        'subject_token': subject,
        'actor_token_type': 'urn:ietf:params:oauth:token-type:jwt',
        'actor_token': actor,
        'audience': 'payments-mcp',
    }).encode()
    with urllib.request.urlopen(
        'http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token',
        data, timeout=10,
    ) as reply:
        downstream = json.load(reply)['access_token']
    return {'Authorization': 'Bearer ' + downstream,
            'x-request-id': headers.get('x-request-id') or headers.get('X-Request-ID', '')}


def build_mcp_tools():
    # Same split and connection settings as the Enterprise-tested reference.
    gated = {t.strip() for t in os.environ.get('KAGENT_REQUIRE_APPROVAL', '').split(',') if t.strip()}
    servers = json.loads(os.environ.get('MCP_SERVERS_CONFIG', '[]'))
    timeout = float(os.environ.get('MCP_CONNECT_TIMEOUT', '60'))
    terminate = os.environ.get('MCP_TERMINATE_ON_CLOSE', 'true').lower() != 'false'
    toolsets = []
    for server in servers:
        url = server.get('url') or ''
        if not url:
            continue
        def conn():
            return StreamableHTTPConnectionParams(url=url, timeout=timeout, terminate_on_close=terminate)
        toolsets.append(MCPToolset(
            connection_params=conn(),
            tool_filter=lambda tool, ctx=None: tool.name not in gated,
            header_provider=delegated_headers,
        ))
        toolsets.append(MCPToolset(
            connection_params=conn(),
            tool_filter=lambda tool, ctx=None: tool.name in gated,
            require_confirmation=refund_requires_confirmation,
            header_provider=delegated_headers,
        ))
    return toolsets


root_agent = Agent(
    model=LiteLlm(model='anthropic/claude-haiku-4-5'),
    name='ledger_agent',
    description='Investigate and refund failed TrustUs Bank payments.',
    instruction=INSTRUCTION,
    tools=build_mcp_tools(),
)
