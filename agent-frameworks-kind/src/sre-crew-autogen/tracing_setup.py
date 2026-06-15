"""Minimal OTel tracing for the AutoGen BYO shim.

AutoGen has no kagent-core, so this sets up what kagent-core would: a TracerProvider
exporting OTLP to OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, plus OpenAI instrumentation so
the model calls (and the tool calls in them) emit GenAI spans that agentevals scores.
Gated by OTEL_TRACING_ENABLED so it is a no-op unless tracing is turned on.
"""
from __future__ import annotations

import logging
import os


def configure_tracing(service_name: str = "sre-crew-autogen") -> None:
    if os.getenv("OTEL_TRACING_ENABLED", "false").lower() != "true":
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider(
        resource=Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", service_name)})
    )
    # OTLPSpanExporter reads OTEL_EXPORTER_OTLP_TRACES_ENDPOINT (used verbatim, so it
    # must include /v1/traces) or the general endpoint.
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    try:
        from opentelemetry.instrumentation.openai import OpenAIInstrumentor

        OpenAIInstrumentor().instrument()
    except Exception as e:  # noqa: BLE001
        logging.warning("OpenAI instrumentation unavailable: %s", e)
    try:
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

        HTTPXClientInstrumentor().instrument()
    except Exception:  # noqa: BLE001
        pass
    logging.info("OTel tracing configured for %s", service_name)
