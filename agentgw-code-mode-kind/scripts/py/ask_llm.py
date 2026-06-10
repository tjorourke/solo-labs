# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2", "anthropic>=0.40"]
# ///
"""ask_llm.py "<task>" — let Claude drive the run_code tool.

This is the point of code mode. Claude is handed exactly one tool, run_code,
whose description is the generated TypeScript API. It reads that API, writes a
JavaScript program against it, and sends the program as the tool input. The
gateway runs it and returns the result. Claude never sees the four petstore
operations as separate tools, and never makes four separate tool calls - it
writes one program that does the whole job.

Needs ANTHROPIC_API_KEY in the environment. MODEL overrides the default.
"""

import asyncio
import json
import os
import sys

from anthropic import Anthropic

from _codemode import RUN_CODE, mcp_session, tool_text

MODEL = os.environ.get("MODEL", "claude-sonnet-4-6")
MAX_TURNS = 6
DEFAULT_TASK = (
    "How many pets are currently available, broken down by category? "
    "Then show me three example available pets with their name and category."
)


def _indent(text: str, prefix: str = "    ") -> str:
    return "\n".join(prefix + line for line in text.splitlines())


async def main() -> None:
    task = " ".join(sys.argv[1:]).strip() or DEFAULT_TASK
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY is not set")

    client = Anthropic()

    async with mcp_session() as session:
        tools = (await session.list_tools()).tools
        run_code = next((t for t in tools if t.name == RUN_CODE), None)
        if run_code is None:
            sys.exit("no run_code tool — is the backend in code mode (toolMode: Code)?")

        anthropic_tool = {
            "name": run_code.name,
            "description": run_code.description or "",
            "input_schema": run_code.inputSchema,
        }

        print(f"\nModel:  {MODEL}")
        print(f"Task:   {task}\n")

        messages = [{"role": "user", "content": task}]
        for turn in range(1, MAX_TURNS + 1):
            resp = client.messages.create(
                model=MODEL,
                max_tokens=2048,
                tools=[anthropic_tool],
                messages=messages,
            )

            # Surface any prose Claude emitted alongside its tool use.
            for block in resp.content:
                if block.type == "text" and block.text.strip():
                    print(f"[turn {turn}] Claude:\n{_indent(block.text.strip())}\n")

            if resp.stop_reason != "tool_use":
                return

            messages.append({"role": "assistant", "content": resp.content})
            tool_results = []
            for block in resp.content:
                if block.type != "tool_use":
                    continue
                code = block.input.get("code", "")
                print(f"[turn {turn}] Claude wrote JavaScript for run_code:\n{_indent(code)}\n")
                result = await session.call_tool(RUN_CODE, {"code": code})
                output = tool_text(result)
                print(f"[turn {turn}] run_code returned:\n{_indent(output)}\n")
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": output,
                    }
                )
            messages.append({"role": "user", "content": tool_results})

        print(f"(stopped after {MAX_TURNS} turns)")


if __name__ == "__main__":
    asyncio.run(main())
