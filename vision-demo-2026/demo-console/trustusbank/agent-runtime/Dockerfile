ARG DOCKER_REGISTRY=ghcr.io
# Must match the OSS kagent the enterprise controller runs (its -image-tag):
# kagent-enterprise 0.5.9 is 0.10.0-rc5, whose task store needs a user_id the
# 0.8 ADK never sends, so the A2A stream dies with "unexpected EOF".
ARG VERSION=0.10.0-rc5
FROM $DOCKER_REGISTRY/kagent-dev/kagent/kagent-adk:$VERSION AS base

# The 0.10 base is distroless (no shell, no pip, user 65532) and carries
# google-adk but not LiteLLM, which the agent uses to reach Gemma. Install it
# into the base's own venv in a stage that has a shell, then copy the venv back.
FROM debian:bookworm-slim AS deps
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/uv
COPY --from=base /python /python
COPY --from=base /.kagent/.venv /.kagent/.venv
RUN uv pip install --python /.kagent/.venv/bin/python --no-cache "litellm==1.103.2"

FROM base
COPY --from=deps /.kagent/.venv /.kagent/.venv
WORKDIR /app
COPY myagents/ myagents/

ENV OTEL_SERVICE_NAME=trustusbank-agents
ENV PYTHONPATH=/app

CMD ["myagents"]
