package io.solo.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.google.adk.agents.LlmAgent;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The two endpoints kagent needs from a BYO agent.
 *
 * There is no A2A SDK on Maven Central for Java, and the contract is small enough not to
 * want one: a static agent card for the readiness probe, and JSON-RPC {@code message/send}
 * for the question. Serving it here is what makes this a long-lived pod rather than a
 * batch job, so kagent can run it exactly as it runs the Python agent.
 */
final class A2aServer {

  private static final String CARD = """
      {
        "capabilities": { "streaming": false },
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "description": "%s",
        "name": "%s",
        "preferredTransport": "JSONRPC",
        "protocolVersion": "0.3.0",
        "skills": [{ "id": "%s", "name": "%s", "description": "%s", "tags": ["%s"] }],
        "url": "http://localhost:8080",
        "version": "0.0.1"
      }""";

  private final LlmAgent agent;
  private final String name;
  private final String description;
  private final AtomicInteger turns = new AtomicInteger();

  A2aServer(LlmAgent agent, String description) {
    this.agent = agent;
    this.name = Optional.ofNullable(System.getenv("KAGENT_NAME")).orElse("prtriage-java");
    this.description = description;
  }

  void start(int port) throws IOException, InterruptedException {
    var http = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
    http.createContext("/.well-known/agent-card.json", json(this::card));
    http.createContext("/", json(this::messageSend));
    http.setExecutor(Executors.newFixedThreadPool(4));
    http.start();
    Console.serving(port);
    Thread.currentThread().join();
  }

  private String card(JsonNode request) {
    return CARD.formatted(description, name, name, name, description, name);
  }

  private String messageSend(JsonNode request) {
    var id = request.path("id");
    if (!"message/send".equals(request.path("method").asText())) {
      return Json.write(Json.object()
          .put("jsonrpc", "2.0")
          .putRawValue("id", raw(id))
          .set("error", Json.object()
              .put("code", -32601)
              .put("message", "only message/send is implemented")));
    }

    var prompt = firstTextPart(request);
    Console.turn(turns.incrementAndGet(), prompt);

    String answer;
    try {
      answer = Turn.finalText(Turn.of(agent, name).ask(prompt));
    } catch (RuntimeException e) {
      answer = "the agent failed: " + e.getMessage();
      Console.failed(answer);
    }

    var part = Json.object().put("kind", "text").put("text", answer);
    var artifact = Json.object().put("artifactId", "report");
    artifact.putArray("parts").add(part);
    var result = Json.object();
    result.putArray("artifacts").add(artifact);

    return Json.write(Json.object()
        .put("jsonrpc", "2.0")
        .putRawValue("id", raw(id))
        .set("result", result));
  }

  /** The user's question is the first text part of the A2A message. */
  private static String firstTextPart(JsonNode request) {
    return Optional.of(request.findValuesAsText("text"))
        .filter(texts -> !texts.isEmpty())
        .map(texts -> texts.get(0))
        .orElse("");
  }

  private static com.fasterxml.jackson.databind.util.RawValue raw(JsonNode id) {
    return new com.fasterxml.jackson.databind.util.RawValue(
        id.isMissingNode() ? "\"1\"" : id.toString());
  }

  /** Reads a JSON request, writes a JSON response, and turns anything thrown into a 500. */
  private static HttpHandler json(Endpoint endpoint) {
    return exchange -> {
      String body;
      try (var in = exchange.getRequestBody()) {
        body = new String(in.readAllBytes(), StandardCharsets.UTF_8);
      }
      var request = body.isBlank() ? Json.object() : Json.parse(body);
      String response;
      int status = 200;
      try {
        response = endpoint.handle(request);
      } catch (RuntimeException e) {
        status = 500;
        response = Json.write(Json.object().put("error", String.valueOf(e.getMessage())));
        Console.failed(String.valueOf(e.getMessage()));
      }
      send(exchange, status, response);
    };
  }

  private static void send(HttpExchange exchange, int status, String body) throws IOException {
    var bytes = body.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().add("Content-Type", "application/json");
    exchange.sendResponseHeaders(status, bytes.length);
    try (var out = exchange.getResponseBody()) {
      out.write(bytes);
    }
  }

  @FunctionalInterface
  private interface Endpoint {
    String handle(JsonNode request);
  }
}
