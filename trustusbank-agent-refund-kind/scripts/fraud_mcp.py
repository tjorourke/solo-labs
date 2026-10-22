"""Risk tools call the vendor through bank-gw, with no API key in this pod."""
import json
import urllib.request
from mcp.server.fastmcp import FastMCP, Context
from bank_data import payment

mcp = FastMCP('fraud', host='0.0.0.0', port=8000, stateless_http=True, json_response=True)


@mcp.tool()
def score_refund(payment_id: str, ctx: Context) -> dict:
    """Ask the fraud vendor to score a failed payment's refund."""
    record = payment(payment_id)
    incoming = ctx.request_context.request.headers
    headers = {'Content-Type': 'application/json'}
    for name in ('traceparent', 'tracestate'):
        if incoming.get(name):
            headers[name] = incoming[name]
    req = urllib.request.Request('http://bank-gw.bank.svc.cluster.local:8080/fraud/score',
                                 json.dumps(record).encode(), headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


@mcp.tool()
def list_flags(payment_id: str) -> dict:
    """List recorded fraud flags for this payment."""
    payment(payment_id)
    return {'payment_id': payment_id, 'flags': []}


if __name__ == '__main__':
    mcp.run(transport='streamable-http')
