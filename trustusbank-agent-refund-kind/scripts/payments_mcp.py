"""Disposable payment tools. The gateway owns token verification and tool policy."""
from mcp.server.fastmcp import FastMCP, Context
from bank_data import payment
import json
import urllib.request
import urllib.error

mcp = FastMCP('payments', host='0.0.0.0', port=8000, stateless_http=True, json_response=True)


@mcp.tool()
def get_payment(payment_id: str) -> dict:
    """Read the payment and its current bank refund receipt. This never moves money."""
    record = payment(payment_id)
    with urllib.request.urlopen('http://bank-gw.bank.svc.cluster.local:8080/core/refunds', timeout=5) as reply:
        receipts = json.load(reply)['refunds']
    receipt = next((r for r in receipts if r['payment_id'] == payment_id), None)
    return {**record, 'refund_status': 'ISSUED' if receipt else 'NOT_ISSUED', 'refund_receipt': receipt}


@mcp.tool()
def refund_payment(payment_id: str, amount_gbp: float, ctx: Context) -> dict:
    """Refund exactly the recorded amount of a failed payment."""
    if amount_gbp != payment(payment_id)['amount_gbp']:
        raise ValueError('Refund must equal the recorded payment amount')
    incoming = ctx.request_context.request.headers
    headers = {'Content-Type': 'application/json'}
    # Identity headers are overwritten from verified claims at bank-gw.
    for name in ('x-bank-sub', 'x-bank-actor', 'x-bank-user', 'traceparent', 'tracestate'):
        if incoming.get(name):
            headers[name] = incoming[name]
    request = urllib.request.Request(
        'http://bank-gw.bank.svc.cluster.local:8080/core/refund',
        data=json.dumps({'payment_id': payment_id, 'amount_gbp': amount_gbp}).encode(),
        headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=10) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as error:
        raise ValueError(f'Core bank refused refund: HTTP {error.code}') from error


@mcp.tool()
def refund_payment_with_approval(payment_id: str, amount_gbp: float, ctx: Context) -> dict:
    """Request human approval and then issue a refund above the autonomous limit.

    The payments manager must attach kagent requireApproval to this tool.
    The gateway permits only Payment Management through that assistant.
    """
    return refund_payment(payment_id, amount_gbp, ctx)


if __name__ == '__main__':
    mcp.run(transport='streamable-http')
