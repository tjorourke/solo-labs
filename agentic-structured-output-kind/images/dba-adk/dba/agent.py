"""dba-adk — the BYO half of the contract.

Same Diagnosis shape as the declarative DBA, but here the shape is enforced in
code: a pydantic BaseModel handed to the ADK LlmAgent as output_schema. ADK holds
the model to that schema, so the agent's final answer IS the typed record, not
prose that happens to look like JSON.

ADK rule: an agent with output_schema cannot also use tools. That is fine here —
the SRE orchestrator does the investigating and hands this agent the evidence
(pod logs, events) in the A2A message. This agent only maps evidence -> verdict.

The kagent-adk base image boots an A2A server for `root_agent`, so kagent invokes
this like any other agent (tools[].type: Agent from the orchestrator).
"""
from __future__ import annotations

import os

from google.adk.agents import LlmAgent
from google.adk.models.lite_llm import LiteLlm
from pydantic import BaseModel, Field


# The contract — the on-disk mirror is yaml/contract/diagnosis.schema.json. Keep
# the two in lockstep: this pydantic model and the record_diagnosis MCP tool are
# two enforcements of one shape.
class Diagnosis(BaseModel):
    root_cause: str = Field(description="What is actually broken, in one or two sentences.")
    severity: str = Field(description="How bad it is: low, medium, high, or critical.")
    fix: str = Field(description="The exact remediation the on-call should apply.")
    runbook_url: str = Field(default="", description="Link to the matching runbook, or empty string.")


# Anthropic via LiteLlm. Override the model with DBA_MODEL at deploy time.
_MODEL = os.environ.get("DBA_MODEL", "anthropic/claude-sonnet-4-5-20250929")

root_agent = LlmAgent(
    model=LiteLlm(model=_MODEL),
    name="dba_agent_byo",
    description="Database SRE specialist. Returns a strict, machine-readable Diagnosis.",
    instruction="""
      You are a database reliability specialist. You are handed evidence about a
      failing database workload (pod status, logs, events) collected by the SRE
      on-call. Read it, work out the root cause, and return the Diagnosis.

      Do not ask questions and do not write prose. If a field is unknown, still
      answer: use a short best-effort string and pick the closest severity rather
      than inventing detail. runbook_url may be an empty string.
    """,
    output_schema=Diagnosis,
    # output_schema agents must not hand control elsewhere.
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)
