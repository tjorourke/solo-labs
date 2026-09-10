package io.solo.demo;

import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

/**
 * Turn ADK's spans into spans that actually leave the process.
 *
 * ADK instruments itself: {@code Tracing.traceCallLlm}, {@code traceToolExecution} and
 * the rest are called for every turn. But they resolve through the global
 * OpenTelemetry instance, and if nothing has configured one that global is a no-op, so
 * the spans are created and dropped. The symptom is an empty Tracing tab in the kagent
 * UI while everything else works, which is a confusing thing to discover on stage.
 *
 * The autoconfigure extension reads the OTEL_* environment variables kagent already
 * injects into every agent it deploys: the collector endpoint, the protocol, the
 * timeouts. So this is the whole integration.
 */
final class Telemetry {

  private Telemetry() {}

  static void start(String serviceName) {
    if (!Boolean.parseBoolean(System.getenv().getOrDefault("OTEL_TRACING_ENABLED", "false"))) {
      return;
    }
    // The collector groups spans by service name, and kagent does not set it, so name
    // ourselves after the agent rather than appearing as "unknown_service:java".
    if (System.getenv("OTEL_SERVICE_NAME") == null) {
      System.setProperty("otel.service.name", serviceName);
    }
    // Metrics and logs are not wanted here, only the span tree the Tracing tab reads.
    System.setProperty("otel.metrics.exporter", "none");
    System.setProperty("otel.logs.exporter", "none");
    AutoConfiguredOpenTelemetrySdk.builder().setResultAsGlobal().build();
    Console.tracing(System.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"), serviceName);
  }
}
