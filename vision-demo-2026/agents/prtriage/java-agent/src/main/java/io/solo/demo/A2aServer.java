package io.solo.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.adk.agents.LlmAgent;
import com.google.adk.events.Event;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
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
        "capabilities": { "streaming": true },
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
  private final com.google.adk.tools.BaseToolset gateway;
  private final String name;
  private final String description;
  private final AtomicInteger turns = new AtomicInteger();

  A2aServer(LlmAgent agent, com.google.adk.tools.BaseToolset gateway, String description) {
    this.agent = agent;
    this.name = Optional.ofNullable(System.getenv("KAGENT_NAME")).orElse("prtriage-java");
    this.description = description;
    this.gateway = gateway;
  }

  void start(int port) throws IOException, InterruptedException {
    var http = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
    http.createContext("/.well-known/agent-card.json", json(this::card));
    http.createContext("/", this::root);
    http.setExecutor(Executors.newFixedThreadPool(4));
    http.start();
    Console.serving(port);
    Thread.currentThread().join();
  }

  /**
   * The kagent UI streams. It calls message/stream and requires the response to be
   * text/event-stream; answering with application/json makes the controller give up with
   * "server did not respond with Content-Type 'text/event-stream'", and the UI shows a
   * 500 while the terminal path works perfectly. So the root endpoint dispatches on the
   * method rather than assuming everyone posts message/send.
   */
  private void root(HttpExchange exchange) throws IOException {
    String body;
    try (var in = exchange.getRequestBody()) {
      body = new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
    var request = body.isBlank() ? Json.object() : Json.parse(body);
    if (System.getenv("A2A_DEBUG") != null) {
      System.out.println("  [debug] headers: " + exchange.getRequestHeaders().entrySet());
      System.out.println("  [debug] body: " + body);
    }
    if ("message/stream".equals(request.path("method").asText())) {
      messageStream(exchange, request);
    } else {
      send(exchange, 200, messageSend(request));
    }
  }

  /**
   * One turn, as the event sequence kagent's UI expects.
   *
   * A single completed Task in one frame is not enough: the UI created a session for
   * every prompt and showed nothing in it, not even the message that had just been
   * typed. The sequence below is the one the Python agent emits, captured off the wire
   * and matched frame for frame, because that is the contract in practice.
   *
   *   1. status-update, submitted, carrying the USER's message   (the UI renders this)
   *   2. status-update, working, carrying the kagent_* metadata  (session bookkeeping)
   *   3. status-update, working, carrying the AGENT's message
   *   4. artifact-update with the answer, lastChunk
   *   5. status-update, completed, final                          (without it nothing settles)
   *
   * ADK gives back the whole turn at once, so these are emitted together at the end
   * rather than as the work happens. The shape is honest; the timing is not incremental.
   */
  private void messageStream(HttpExchange exchange, JsonNode request) throws IOException {
    var prompt = firstTextPart(request);
    Console.turn(turns.incrementAndGet(), prompt);

    var taskId = UUID.randomUUID().toString();
    var contextId = text(request, "contextId").orElseGet(() -> UUID.randomUUID().toString());
    var rpcId = request.path("id");
    // Whoever the controller is acting for. It travels in the request metadata under one
    // of these names depending on the caller, and the session store needs it to file the
    // turn against the right conversation.
    var userId = header(exchange, "x-user-id")
        .or(() -> header(exchange, "x-kagent-user-id"))
        .or(() -> header(exchange, "kagent-user-id"))
        .or(() -> text(request, "kagent_user_id"))
        .or(() -> text(request, "user_id"))
        .or(() -> text(request, "userId"))
        .orElse("A2A_USER_" + contextId);
    if (userId.startsWith("A2A_USER_")) {
      // Only when we had to guess. kagent's controller sends X-user-id, and without it
      // the session write fails as "Session not found", because the lookup is by
      // (session, user) and it is the user half that is missing. That error names the
      // session, so it sends you looking in entirely the wrong place.
      Console.failed("no user id on the request, so the UI will not show this turn; "
          + "headers were " + exchange.getRequestHeaders().keySet());
    }

    var headers = exchange.getResponseHeaders();
    headers.add("Content-Type", "text/event-stream");
    headers.add("Cache-Control", "no-cache");
    headers.add("Connection", "keep-alive");
    exchange.sendResponseHeaders(200, 0);          // 0 = chunked, no length up front

    try (var out = exchange.getResponseBody()) {
      // 1. the prompt, echoed back, which is what the UI draws as the user's turn
      var userMessage = Json.object()
          .put("kind", "message")
          .put("role", "user")
          .put("messageId", text(request, "messageId").orElseGet(() -> UUID.randomUUID().toString()))
          .put("contextId", contextId)
          .put("taskId", taskId);
      userMessage.putArray("parts").add(Json.object().put("kind", "text").put("text", prompt));
      var submitted = Json.object().put("state", "submitted").put("timestamp", Instant.now().toString());
      submitted.set("message", userMessage);
      frame(out, rpcId, statusUpdate(taskId, contextId, submitted, false, true));

      // 2. working, with the bookkeeping kagent uses to file the session
      frame(out, rpcId, statusUpdate(taskId, contextId,
          Json.object().put("state", "working").put("timestamp", Instant.now().toString()), false, true));

      List<Event> events = List.of();
      String answer;
      try {
        // No progress frames. ADK Java hands every event over when the turn FINISHES:
        // instrumented, all eighteen tool calls arrived within six milliseconds of each
        // other at the end of a seventy second run. Emitting a frame per call therefore
        // dumps eighteen messages at once rather than showing progress, so the wait
        // stays a wait and the transcript stays clean.
        events = Turn.of(agent, name).ask(prompt);
        answer = Turn.finalText(events);
      } catch (RuntimeException e) {
        var cause = e.getCause() == null ? e : e.getCause();
        var detail = cause.getMessage() == null ? "" : cause.getMessage();
        // A turn can die because the conversation ADK assembled is malformed: a tool_use
        // with no tool_result after it, which the provider rejects with a 400. It is not
        // the question that is wrong, and a fresh session usually completes. Retry once,
        // and only for that, so real failures still surface.
        if (detail.contains("tool_use") && detail.contains("tool_result")) {
          Console.failed("malformed tool history from the previous attempt, retrying once");
          try {
            events = Turn.of(agent, name).ask(prompt);
            answer = Turn.finalText(events);
          } catch (RuntimeException retry) {
            // Twice is not bad luck. An agent the gateway generated nothing for cannot
            // make progress, and the model thrashes until the conversation is malformed.
            // Report what it was actually given rather than a stack trace: that is an
            // observation, and it happens to be the answer.
            answer = toolsOffered()
                .map(tools -> tools.isEmpty()
                    ? "I could not complete this. The gateway generated no tools at all "
                      + "for this agent, so there is nothing here to read pull requests with."
                    : "I could not complete this. The gateway generated only these tools "
                      + "for this agent: " + String.join(", ", tools)
                      + " - and none of them reaches GitHub.")
                .orElseGet(() -> {
                  var rc = retry.getCause() == null ? retry : retry.getCause();
                  return "the agent failed: %s: %s".formatted(rc.getClass().getSimpleName(),
                      rc.getMessage() == null ? "(no message)" : rc.getMessage());
                });
            Console.failed(answer);
          }
        } else {
          answer = "the agent failed: %s: %s".formatted(cause.getClass().getSimpleName(),
              detail.isEmpty() ? "(no message)" : detail);
          Console.failed(answer);
          e.printStackTrace();
        }
      }

      // The UI reads the conversation from kagent's session store, not from this stream,
      // so both halves of the turn go in there too or the chat renders empty.
      var invocationId = KagentSession.newInvocationId();
      KagentSession.record(contextId, userId, invocationId, "user", prompt);
      KagentSession.record(contextId, userId, invocationId, name + "_agent", answer);

      // 3. the answer as a message
      var agentMessage = Json.object()
          .put("kind", "message")
          .put("role", "agent")
          .put("messageId", UUID.randomUUID().toString())
          .put("contextId", contextId)
          .put("taskId", taskId);
      agentMessage.putArray("parts").add(Json.object().put("kind", "text").put("text", answer));
      var working = Json.object().put("state", "working").put("timestamp", Instant.now().toString());
      working.set("message", agentMessage);
      frame(out, rpcId, statusUpdate(taskId, contextId, working, false, true));

      // 4. and as an artifact
      var artifact = Json.object().put("artifactId", UUID.randomUUID().toString()).put("name", "report");
      artifact.putArray("parts").add(Json.object().put("kind", "text").put("text", answer));
      var artifactUpdate = Json.object()
          .put("kind", "artifact-update")
          .put("taskId", taskId)
          .put("contextId", contextId)
          .put("lastChunk", true);
      artifactUpdate.set("artifact", artifact);
      frame(out, rpcId, artifactUpdate);

      // 5. final. Without this the client waits, and the session stays empty.
      frame(out, rpcId, statusUpdate(taskId, contextId,
          Json.object().put("state", "completed").put("timestamp", Instant.now().toString()), true, true));
    }
  }

  /** A status-update event, optionally carrying the kagent session bookkeeping. */
  private ObjectNode statusUpdate(String taskId, String contextId, ObjectNode status,
                                  boolean isFinal, boolean withMetadata) {
    var event = Json.object()
        .put("kind", "status-update")
        .put("taskId", taskId)
        .put("contextId", contextId)
        .put("final", isFinal);
    event.set("status", status);
    if (withMetadata) {
      event.set("metadata", Json.object()
          .put("kagent_app_name", "kagent__NS__" + name)
          .put("kagent_user_id", "A2A_USER_" + contextId)
          .put("kagent_session_id", contextId));
    }
    return event;
  }

  private void frame(java.io.OutputStream out, JsonNode rpcId, ObjectNode result) throws IOException {
    var envelope = Json.object().put("jsonrpc", "2.0").putRawValue("id", raw(rpcId));
    envelope.set("result", result);
    out.write(("data: " + Json.write(envelope) + "\n\n").getBytes(StandardCharsets.UTF_8));
    out.flush();
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
              .put("message", "only message/send and message/stream are implemented")));
    }

    var prompt = firstTextPart(request);
    Console.turn(turns.incrementAndGet(), prompt);

    List<Event> events = List.of();
    String answer;
    try {
      events = Turn.of(agent, name).ask(prompt);
      answer = Turn.finalText(events);
    } catch (RuntimeException e) {
      // Name the type and the cause. Several of the exceptions that come out of the
      // model and MCP layers carry a null message, and "the agent failed: null" tells
      // whoever is standing in front of the room nothing at all.
      var cause = e.getCause() == null ? e : e.getCause();
      answer = "the agent failed: %s: %s".formatted(
          cause.getClass().getSimpleName(),
          cause.getMessage() == null ? "(no message)" : cause.getMessage());
      Console.failed(answer);
      e.printStackTrace();
    }

    return Json.write(Json.object()
        .put("jsonrpc", "2.0")
        .putRawValue("id", raw(id))
        .set("result", task(request, answer, events)));
  }

  /**
   * A2A message/send returns either a Message or a Task, and the receiver switches on
   * the "kind" discriminator. Omit it and kagent's controller rejects the response with
   * "unsupported result kind" even though the answer itself is perfectly good, which is
   * a confusing half hour if you have not read the spec.
   */
  private ObjectNode task(JsonNode request, String answer, List<Event> events) {
    var part = Json.object().put("kind", "text").put("text", answer);

    var artifact = Json.object().put("artifactId", "report").put("name", "report");
    artifact.putArray("parts").add(part);

    var message = Json.object()
        .put("kind", "message")
        .put("role", "agent")
        .put("messageId", UUID.randomUUID().toString());
    message.putArray("parts").add(part.deepCopy());

    var status = Json.object()
        .put("state", "completed")
        .put("timestamp", Instant.now().toString());
    status.set("message", message);

    var task = Json.object()
        .put("kind", "task")
        .put("id", text(request, "taskId").orElseGet(() -> UUID.randomUUID().toString()))
        .put("contextId", text(request, "contextId").orElseGet(() -> UUID.randomUUID().toString()));
    task.set("status", status);
    task.putArray("artifacts").add(artifact);
    // The tool calls go in history as data parts, which is where an A2A client looks
    // for them. Without this the caller sees the answer but not how it was reached, and
    // the trace is the whole point of the demo.
    var history = task.putArray("history");
    for (var call : Turn.toolCalls(events)) {
      var data = Json.object()
          .put("name", call.name().orElse("unnamed"))
          .put("id", call.id().orElse(""));
      data.set("args", Json.MAPPER.valueToTree(call.args().orElse(Map.of())));
      history.add(dataMessage(data));
    }
    // The responses matter as much as the calls: they are the payload that crossed the
    // model's context window, and a client counting bytes has nowhere else to find it.
    for (var response : Turn.toolResponses(events)) {
      var data = Json.object()
          .put("name", response.name().orElse("unnamed"))
          .put("id", response.id().orElse(""));
      data.set("response", Json.MAPPER.valueToTree(response.response().orElse(Map.of())));
      history.add(dataMessage(data));
    }
    return task;
  }

  /** One history entry: an agent message carrying a single data part. */
  private static ObjectNode dataMessage(ObjectNode data) {
    var dataPart = Json.object().put("kind", "data");
    dataPart.set("data", data);
    var entry = Json.object()
        .put("kind", "message")
        .put("role", "agent")
        .put("messageId", UUID.randomUUID().toString());
    entry.putArray("parts").add(dataPart);
    return entry;
  }

  /** First value of a named field anywhere in the request, if it is there at all. */
  /** The tool names the gateway generated for THIS agent, when they can be listed. */
  private Optional<List<String>> toolsOffered() {
    try {
      return Optional.of(gateway.getTools(null)
          .map(com.google.adk.tools.BaseTool::name)
          .filter(n -> !"run_code".equals(n) && !"get_tool".equals(n))
          .toList().blockingGet());
    } catch (Exception e) {
      return Optional.empty();
    }
  }

  private static Optional<String> header(HttpExchange exchange, String name) {
    return Optional.ofNullable(exchange.getRequestHeaders().getFirst(name))
        .filter(v -> !v.isBlank());
  }

  private static Optional<String> text(JsonNode request, String field) {
    return Optional.of(request.findValuesAsText(field))
        .filter(values -> !values.isEmpty())
        .map(values -> values.get(0))
        .filter(value -> !value.isBlank());
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
