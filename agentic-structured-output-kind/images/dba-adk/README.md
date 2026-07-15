# dba-adk

The BYO half of the lab. A Google ADK `LlmAgent` whose `output_schema` is the
`Diagnosis` pydantic model, so the shape is enforced in code. No tools (ADK
disallows tools alongside `output_schema`) — the orchestrator hands it the
evidence and it returns the typed verdict. Built on the `kagent-adk` base image,
which serves the A2A endpoint for `root_agent`.

`LlmAgent(model=LiteLlm(...))` needs LiteLLM in the base image's own venv (the one
the `kagent-adk` entrypoint runs from, `/.kagent/.venv`), so the Dockerfile does
`uv pip install --python /.kagent/.venv litellm` — additive, so it does not
disturb the base venv. google-adk and pydantic are already in the base image.
