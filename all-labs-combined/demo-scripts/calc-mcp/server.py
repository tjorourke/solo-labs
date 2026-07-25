# Minimal calculator MCP server (streamable HTTP) for the Code Mode demo.
# Tool names match the run_code program on the slide: add/sub/mul/div/sqrt/pow.
import math
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("calculator", host="0.0.0.0", port=3000)

@mcp.tool()
def add(a: float, b: float) -> float:
    """Add two numbers: a + b."""
    return a + b

@mcp.tool()
def sub(a: float, b: float) -> float:
    """Subtract: a - b."""
    return a - b

@mcp.tool()
def mul(a: float, b: float) -> float:
    """Multiply two numbers: a * b."""
    return a * b

@mcp.tool()
def div(a: float, b: float) -> float:
    """Divide: a / b."""
    return a / b

@mcp.tool()
def sqrt(x: float) -> float:
    """Square root of x."""
    return math.sqrt(x)

@mcp.tool()
def pow(a: float, b: float) -> float:
    """a raised to the power b."""
    return a ** b

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
