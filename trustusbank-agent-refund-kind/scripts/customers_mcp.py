"""Read-only customer MCP service. No downstream credential is mounted here."""
from mcp.server.fastmcp import FastMCP
from bank_data import payment

mcp = FastMCP('customers', host='0.0.0.0', port=8000, stateless_http=True, json_response=True)


@mcp.tool()
def get_customer(payment_id: str) -> dict:
    """Get the customer and the recorded status of a specific payment."""
    return payment(payment_id)


@mcp.tool()
def get_contact_history(payment_id: str) -> dict:
    """Get the customer's contact about a failed payment."""
    record = payment(payment_id)
    return {'customer_id': record['customer_id'], 'payment_id': payment_id,
            'contacts': ['Customer called this morning: money left account, merchant not paid.']}


if __name__ == '__main__':
    mcp.run(transport='streamable-http')
