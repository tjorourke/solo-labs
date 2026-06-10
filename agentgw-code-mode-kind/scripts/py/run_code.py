# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2"]
# ///
"""run_code.py — call the single run_code tool with a JavaScript program.

No LLM here. This is the raw mechanic: the client sends JavaScript, the gateway
runs it in its sandbox, calling the petstore upstream for each addPet/getPetById/
findPetsByStatus call, and returns only what the final expression evaluates to.
The whole add -> read back -> summarise flow is one MCP call, one round trip.

Pass your own JS as an argument or on stdin to experiment; otherwise the default
program below runs.
"""

import asyncio
import json
import sys

from _codemode import RUN_CODE, mcp_session, run_code_payload

DEFAULT_CODE = """
// One run_code call does the whole task. Each await is a petstore REST call the
// gateway makes for us; the counting, grouping and per-pet detail lookups happen
// here, server-side, so only the small final summary crosses the wire back.
// (OpenAPI list responses come back wrapped as { data: [...] } - unwrap it.)
const res = await findPetsByStatus({ query: { status: "available" } });
const pets = res.data ?? res;

// Fetch full detail for the first few, in parallel, in the same call.
const sample = pets.filter((p) => Number.isSafeInteger(p.id)).slice(0, 3);
const detailed = await Promise.all(sample.map((p) => getPetById({ path: { petId: p.id } })));

({
  availableCount: pets.length,
  byCategory: pets.reduce((acc, p) => {
    const c = (p.category && p.category.name) || "uncategorised";
    acc[c] = (acc[c] || 0) + 1;
    return acc;
  }, {}),
  sampleDetail: detailed.map((d) => {
    const p = d.data ?? d;
    return { id: p.id, name: p.name, category: (p.category && p.category.name) || null };
  }),
})
""".strip()


async def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "-":
        code = sys.stdin.read()
    elif len(sys.argv) > 1:
        code = sys.argv[1]
    else:
        code = DEFAULT_CODE

    print("\nJavaScript sent to run_code:\n")
    print("\n".join("    " + line for line in code.splitlines()))

    async with mcp_session() as session:
        result = await session.call_tool(RUN_CODE, {"code": code})
        payload = run_code_payload(result)

    print("\nrun_code returned:\n")
    print(json.dumps(payload, indent=2))
    if "error" in payload:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
