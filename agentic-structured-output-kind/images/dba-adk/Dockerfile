# Built on the kagent-adk base image, which provides the A2A server entrypoint.
# CMD is the package name; the base boots an A2A server hosting dba/agent.py's
# root_agent. VERSION tracks the kagent version the cluster runs (ghcr tags have
# no leading v, e.g. kagent-adk:0.9.4).
ARG DOCKER_REGISTRY=ghcr.io
ARG VERSION=0.9.4
FROM $DOCKER_REGISTRY/kagent-dev/kagent/kagent-adk:$VERSION

WORKDIR /app

# The kagent-adk entrypoint runs from the base image's own venv, so our extra dep
# has to land there too. google-adk and pydantic are already in the base; add
# LiteLLM so LlmAgent(model=LiteLlm(...)) can import it. uv pip install is
# additive (unlike uv sync) so it does not disturb the base venv's kagent-adk.
# --python targets the base image's venv (where the kagent-adk entrypoint runs).
RUN uv pip install --python /.kagent/.venv litellm

# The agent package. `import dba` resolves from the /app working directory.
COPY dba/ dba/

CMD ["dba"]
