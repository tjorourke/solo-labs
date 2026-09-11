package io.solo.labs.sretriage;

import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;

/**
 * Makes ADK's spans leave the process.
 *
 * ADK instruments every model call and tool call, through the global OpenTelemetry
 * instance. Unconfigured, that global is a no-op and the spans are dropped, so the
 * kagent UI's Tracing tab stays empty while everything else works. The autoconfigure
 * extension reads the OTEL_* variables kagent injects into every agent pod, so this is
 * the whole integration.
 */
final class Telemetry {

  private Telemetry() {}

  static void start(String serviceName) {
    if (!Boolean.parseBoolean(System.getenv().getOrDefault("OTEL_TRACING_ENABLED", "false"))) {
      return;
    }
    // The collector groups spans by service name and kagent does not set one.
    if (System.getenv("OTEL_SERVICE_NAME") == null) {
      System.setProperty("otel.service.name", serviceName);
    }
    // Only the span tree is wanted here.
    System.setProperty("otel.metrics.exporter", "none");
    System.setProperty("otel.logs.exporter", "none");
    AutoConfiguredOpenTelemetrySdk.builder().setResultAsGlobal().build();
    Console.tracing(System.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"), serviceName);
  }
}
