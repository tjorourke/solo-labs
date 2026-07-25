#!/usr/bin/env python3
"""Make a scaffolded ADK agent multi-cloud for AWS Bedrock AgentCore.

Rewrites <project>/<module>/agent.py so the model is chosen at runtime by the
MODEL_PROVIDER env var (bedrock -> BedrockClaude, otherwise LiteLlm/Anthropic),
and adds the anthropic[bedrock] dependency to pyproject.toml. Idempotent: a
re-run is a no-op once MODEL_PROVIDER is already wired in.

Usage:
  agentcore_multicloud_patch.py <project-dir> [<agent-module>]
    <project-dir>   scaffolded project root (e.g. ./agentdemo)
    <agent-module>  inner package dir (default: basename of <project-dir>)
"""
import re
import sys
import pathlib


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: agentcore_multicloud_patch.py <project-dir> [<agent-module>]", file=sys.stderr)
        sys.exit(2)
    proj = pathlib.Path(sys.argv[1])
    module = sys.argv[2] if len(sys.argv) > 2 else proj.name

    agent_py = proj / module / "agent.py"
    s = agent_py.read_text()
    if "MODEL_PROVIDER" not in s:
        s = s.replace("from google.adk.models.lite_llm import LiteLlm\n", "")
        # NB: re-add `mcp_tools = get_mcp_tools()`. It sits between create_model()
        # and root_agent, so the regex below (which spans up to root_agent) would
        # otherwise delete it — and agent.py references mcp_tools in root_agent's
        # tools list, so AgentCore would fail to load the module with
        # "name 'mcp_tools' is not defined".
        new = (
            "def create_model():\n"
            "    import os\n"
            '    if os.environ.get("MODEL_PROVIDER", "anthropic").lower() == "bedrock":\n'
            "        from .bedrock_model import BedrockClaude\n"
            '        return BedrockClaude(model=os.environ.get("MODEL_NAME", "us.anthropic.claude-haiku-4-5-20251001-v1:0"))\n'
            "    from google.adk.models.lite_llm import LiteLlm\n"
            '    return LiteLlm(model=os.environ.get("MODEL_NAME", "anthropic/claude-haiku-4-5"))\n'
            "\n"
            "mcp_tools = get_mcp_tools()\n"
        )
        s = re.sub(
            r"def create_model\(\):.*?(?=\n\nroot_agent|\nroot_agent|\Z)",
            new.rstrip() + "\n",
            s,
            count=1,
            flags=re.S,
        )
        agent_py.write_text(s)

    pyproject = proj / "pyproject.toml"
    t = pyproject.read_text()
    if "anthropic[bedrock]" not in t:
        pyproject.write_text(t.replace("dependencies = [", 'dependencies = [\n  "anthropic[bedrock]>=0.40",', 1))

    print("  multi-cloud patch applied")


if __name__ == "__main__":
    main()
