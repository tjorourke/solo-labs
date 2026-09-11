# The kagent Python runtime is the base image. Its entrypoint is
# `kagent-adk run --host 0.0.0.0 --port 8080`, and CMD names the package to load, so the
# image is the runtime plus one directory of Python.
ARG KAGENT_ADK_VERSION=0.8.0-beta6
FROM ghcr.io/kagent-dev/kagent/kagent-adk:${KAGENT_ADK_VERSION}

WORKDIR /app
COPY sretriage/ sretriage/

ENV OTEL_SERVICE_NAME=sre-python
CMD ["sretriage"]
