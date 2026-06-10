# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""show_tools.py — list what the gateway exposes over MCP.

In code mode this is a single `run_code` tool. Its description is the generated
TypeScript API the client writes against: one `async function` per petstore
operation, plus the rules for how `run_code` executes JavaScript. Swap the
backend to toolMode: Standard and the same petstore shows up as four separate
tools instead — run ./scripts/show-tools.sh --standard to see that contrast.
"""

import asyncio

from _codemode import mcp_session


async def main() -> None:
    async with mcp_session() as session:
        tools = (await session.list_tools()).tools
        print(f"\nThe gateway exposes {len(tools)} MCP tool(s):\n")
        for tool in tools:
            print(f"  • {tool.name}")
            schema = tool.inputSchema or {}
            props = ", ".join((schema.get("properties") or {}).keys())
            print(f"      input: {{ {props} }}")
        run_code = next((t for t in tools if t.name == "run_code"), None)
        if run_code is None:
            print(
                "\nNo run_code tool — this backend is not in code mode "
                "(toolMode: Code). Each operation is its own tool.\n"
            )
            return
        print("\n" + "=" * 72)
        print("run_code description — the generated TypeScript API the client writes against:")
        print("=" * 72 + "\n")
        print(run_code.description)


if __name__ == "__main__":
    asyncio.run(main())
