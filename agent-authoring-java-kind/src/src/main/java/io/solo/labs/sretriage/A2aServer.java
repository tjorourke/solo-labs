package io.solo.labs.sretriage;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.util.RawValue;
import com.google.adk.agents.LlmAgent;
import com.google.adk.events.Event;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
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
 * The HTTP surface kagent expects from a hosted agent.
 *
 * Three things, on the JDK's own HTTP server:
 * <ol>
 *   <li>the agent card at {@code /.well-known/agent-card.json} (kagent's readiness probe)
 *       and at {@code /.well-known/agent.json} (the older A2A path);</li>
 *   <li>JSON-RPC {@code message/send} at {@code /}, answered with a Task;</li>
 *   <li>JSON-RPC {@code message/stream} at {@code /}, answered as text/event-stream in
 *       the frame sequence kagent's UI reads.</li>
 * </ol>
 * After a streamed turn the Task is written to kagent's store through
 * {@link KagentSession}, which is what makes the conversation appear in the UI.
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
        "skills": [{ "id": "triage-namespace", "name": "Triage a namespace",
                     "description": "Report which pods in a namespace are unhealthy and why",
                     "tags": ["kubernetes", "sre", "triage"] }],
        "url": "http://localhost:%d",
        "version": "1.0.0"
      }""";

  private final LlmAgent agent;
  private final Config config;
  private final String name;
  private final AtomicInteger turns = new AtomicInteger();

  A2aServer(LlmAgent agent, Config config) {
    this.agent = agent;
    this.config = config;
    this.name = config.agentName();
  }

  void start() throws IOException, InterruptedException {
    var http = HttpServer.create(new InetSocketAddress("0.0.0.0", config.port()), 0);
    http.createContext("/.well-known/agent-card.json", this::card);
    http.createContext("/.well-known/agent.json", this::card);
    http.createContext("/", this::rpc);
    http.setExecutor(Executors.newFixedThreadPool(4));
    http.start();
    Console.serving(config.port());
    Thread.currentThread().join();
  }

  private void card(HttpExchange exchange) throws IOException {
    send(exchange, 200, CARD.formatted(SreTriage.DESCRIPTION, name, config.port()));
  }

  /** Dispatches on the JSON-RPC method. The UI streams; CLIs and other agents send. */
  private void rpc(HttpExchange exchange) throws IOException {
    String body;
    try (var in = exchange.getRequestBody()) {
      body = new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
    var request = body.isBlank() ? Json.object() : Json.parse(body);
    switch (request.path("method").asText()) {
      case "message/stream" -> messageStream(exchange, request);
      case "message/send" -> send(exchange, 200, Json.write(messageSend(request)));
      default -> send(exchange, 200, Json.write(rpcError(request.path("id"), -32601,
          "only message/send and message/stream are implemented")));
    }
  }

  /**
   * {@code message/stream}: the turn as the SSE frame sequence kagent's runtimes emit.
   * <pre>
   *   1. status-update  submitted   carrying the user's message
   *   2. status-update  working
   *      status-update  working     one per tool call and one per tool result
   *   3. status-update  working     carrying the agent's answer as a message
   *   4. artifact-update            the answer, lastChunk
   *   5. status-update  completed   final: true
   * </pre>
   * Every frame is a JSON-RPC envelope echoing the request id, and every frame after
   * the first carries the kagent metadata block. The user comes from the
   * {@code X-user-id} header the controller adds.
   */
  private void messageStream(HttpExchange exchange, JsonNode request) throws IOException {
    var prompt = firstTextPart(request);
    var rpcId = request.path("id");
    var taskId = UUID.randomUUID().toString();
    var contextId = text(request, "contextId").orElseGet(() -> UUID.randomUUID().toString());
    var invocationId = KagentSession.newInvocationId();
    var userId = header(exchange, "x-user-id").orElse("");
    if (userId.isEmpty()) {
      // Without the user, the task cannot be filed against the caller's session and the
      // UI shows nothing for this turn. Say so once, loudly, and still answer.
      Console.failed("no X-user-id header on message/stream; the turn will not appear in the UI");
    }
    Console.turn(turns.incrementAndGet(), userId.isEmpty() ? "(no user)" : userId, prompt);

    var headers = exchange.getResponseHeaders();
    headers.add("Content-Type", "text/event-stream");
    headers.add("Cache-Control", "no-cache");
    exchange.sendResponseHeaders(200, 0);

    try (var out = exchange.getResponseBody()) {
      var meta = metadata(contextId, userId, invocationId);

      // 1. the question, which the UI draws as the user's turn
      var asked = message("user", text(request, "messageId").orElse(UUID.randomUUID().toString()),
          contextId, taskId, prompt);
      frame(out, rpcId, statusUpdate(taskId, contextId, status("submitted", asked), false, meta));

      // 2. working
      frame(out, rpcId, statusUpdate(taskId, contextId, status("working", null), false, meta));

      // the turn itself, with each tool call streamed as it happens
      List<Event> events = List.of();
      String answer;
      try {
        events = Turn.of(agent, name).ask(prompt,
            call -> progress(out, rpcId, taskId, contextId, meta, call));
        answer = Turn.finalText(events);
      } catch (RuntimeException e) {
        answer = failure(e);
      }

      // the turn, filed where the UI reads it
      var replied = message("agent", UUID.randomUUID().toString(), contextId, taskId, answer);
      replied.set("metadata", meta);
      var stored = task(taskId, contextId, answer, events);
      stored.set("metadata", meta);
      var history = Json.MAPPER.createArrayNode().add(asked);
      stored.get("history").forEach(history::add);
      history.add(replied);
      stored.set("history", history);
      KagentSession.recordEvent(contextId, userId, invocationId, "user", prompt);
      KagentSession.recordEvent(contextId, userId, invocationId, name + "_agent", answer);
      KagentSession.recordTask(contextId, userId, stored);

      // 3. the answer as a message
      frame(out, rpcId, statusUpdate(taskId, contextId, status("working", replied), false, meta));

      // 4. the answer as an artifact
      var artifact = Json.object().put("artifactId", UUID.randomUUID().toString()).put("name", "report");
      artifact.putArray("parts").add(textPart(answer));
      var artifactUpdate = Json.object()
          .put("kind", "artifact-update")
          .put("taskId", taskId)
          .put("contextId", contextId)
          .put("lastChunk", true);
      artifactUpdate.set("artifact", artifact);
      artifactUpdate.set("metadata", meta);
      frame(out, rpcId, artifactUpdate);

      // 5. final
      frame(out, rpcId, statusUpdate(taskId, contextId, status("completed", null), true, meta));
    }
  }

  /**
   * {@code message/send}: the whole turn as one Task. The result carries
   * {@code "kind": "task"}; the controller switches on that discriminator and discards a
   * result without it.
   */
  private ObjectNode messageSend(JsonNode request) {
    var prompt = firstTextPart(request);
    Console.turn(turns.incrementAndGet(), "(message/send)", prompt);
    List<Event> events = List.of();
    String answer;
    try {
      events = Turn.of(agent, name).ask(prompt, call -> {});
      answer = Turn.finalText(events);
    } catch (RuntimeException e) {
      answer = failure(e);
    }
    var taskId = text(request, "taskId").orElseGet(() -> UUID.randomUUID().toString());
    var contextId = text(request, "contextId").orElseGet(() -> UUID.randomUUID().toString());
    var envelope = Json.object().put("jsonrpc", "2.0").putRawValue("id", raw(request.path("id")));
    envelope.set("result", task(taskId, contextId, answer, events));
    return envelope;
  }

  /**
   * A completed Task: the answer as the status message and as an artifact, and the tool
   * calls and their responses in history as data parts, so a caller can see how the
   * answer was reached.
   */
  private ObjectNode task(String taskId, String contextId, String answer, List<Event> events) {
    var artifact = Json.object().put("artifactId", "report").put("name", "report");
    artifact.putArray("parts").add(textPart(answer));
    var task = Json.object()
        .put("kind", "task")
        .put("id", taskId)
        .put("contextId", contextId);
    task.set("status", status("completed", message("agent", UUID.randomUUID().toString(), contextId, taskId, answer)));
    task.putArray("artifacts").add(artifact);
    var history = task.putArray("history");
    for (var call : Turn.toolCalls(events)) {
      var data = Json.object().put("name", call.name().orElse("unnamed")).put("id", call.id().orElse(""));
      data.set("args", Json.MAPPER.valueToTree(call.args().orElse(Map.of())));
      history.add(dataMessage(data));
    }
    for (var response : Turn.toolResponses(events)) {
      var data = Json.object().put("name", response.name().orElse("unnamed")).put("id", response.id().orElse(""));
      data.set("response", Json.MAPPER.valueToTree(response.response().orElse(Map.of())));
      history.add(dataMessage(data));
    }
    return task;
  }

  /**
   * A tool call or its result as a working status-update, in the data-part shape kagent's
   * own runtime streams: {name, args} for the call, {name, response} for the result.
   */
  private void progress(OutputStream out, JsonNode rpcId, String taskId, String contextId,
                        ObjectNode meta, Progress.ToolEvent call) {
    var data = Json.object().put("name", call.name()).put("id", call.id());
    if (call.response() == null) {
      data.set("args", Json.MAPPER.valueToTree(call.args()));
    } else {
      data.set("response", Json.MAPPER.valueToTree(call.response()));
    }
    var message = dataMessage(data);
    message.put("contextId", contextId).put("taskId", taskId);
    message.set("metadata", meta);
    try {
      frame(out, rpcId, statusUpdate(taskId, contextId, status("working", message), false, meta));
    } catch (IOException e) {
      // The client has gone. The turn finishes and the stored task is what anyone coming
      // back will read.
      Console.failed("could not stream a tool call: " + e.getMessage());
    }
  }

  /** The bookkeeping kagent reads off every frame and off the stored task. */
  private ObjectNode metadata(String contextId, String userId, String invocationId) {
    return Json.object()
        .put("kagent_app_name", "kagent__NS__" + name)
        .put("kagent_user_id", userId)
        .put("kagent_session_id", contextId)
        .put("kagent_invocation_id", invocationId)
        .put("kagent_author", name + "_agent")
        .put("kagent_adk_partial", false);
  }

  private static ObjectNode statusUpdate(String taskId, String contextId, ObjectNode status,
                                         boolean isFinal, ObjectNode meta) {
    var event = Json.object()
        .put("kind", "status-update")
        .put("taskId", taskId)
        .put("contextId", contextId)
        .put("final", isFinal);
    event.set("status", status);
    event.set("metadata", meta);
    return event;
  }

  private static ObjectNode status(String state, ObjectNode message) {
    var status = Json.object().put("state", state).put("timestamp", Instant.now().toString());
    if (message != null) {
      status.set("message", message);
    }
    return status;
  }

  private static ObjectNode message(String role, String messageId, String contextId, String taskId, String text) {
    var message = Json.object()
        .put("kind", "message")
        .put("role", role)
        .put("messageId", messageId)
        .put("contextId", contextId)
        .put("taskId", taskId);
    message.putArray("parts").add(textPart(text));
    return message;
  }

  private static ObjectNode dataMessage(ObjectNode data) {
    var part = Json.object().put("kind", "data");
    part.set("data", data);
    var message = Json.object()
        .put("kind", "message")
        .put("role", "agent")
        .put("messageId", UUID.randomUUID().toString());
    message.putArray("parts").add(part);
    return message;
  }

  private static ObjectNode textPart(String text) {
    return Json.object().put("kind", "text").put("text", text);
  }

  private static ObjectNode rpcError(JsonNode id, int code, String message) {
    var envelope = Json.object().put("jsonrpc", "2.0").putRawValue("id", raw(id));
    envelope.set("error", Json.object().put("code", code).put("message", message));
    return envelope;
  }

  /** The failure as the answer, naming the exception: several carry a null message. */
  private static String failure(RuntimeException e) {
    var cause = e.getCause() == null ? e : e.getCause();
    var answer = "the agent failed: %s: %s".formatted(cause.getClass().getSimpleName(),
        cause.getMessage() == null ? "(no message)" : cause.getMessage());
    Console.failed(answer);
    return answer;
  }

  /** One SSE frame, flushed. Tool threads write progress while the handler waits. */
  private static void frame(OutputStream out, JsonNode rpcId, ObjectNode result) throws IOException {
    var envelope = Json.object().put("jsonrpc", "2.0").putRawValue("id", raw(rpcId));
    envelope.set("result", result);
    synchronized (out) {
      out.write(("data: " + Json.write(envelope) + "\n\n").getBytes(StandardCharsets.UTF_8));
      out.flush();
    }
  }

  private static void send(HttpExchange exchange, int status, String body) throws IOException {
    var bytes = body.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().add("Content-Type", "application/json");
    exchange.sendResponseHeaders(status, bytes.length);
    try (var out = exchange.getResponseBody()) {
      out.write(bytes);
    }
  }

  private static Optional<String> header(HttpExchange exchange, String name) {
    return Optional.ofNullable(exchange.getRequestHeaders().getFirst(name)).filter(v -> !v.isBlank());
  }

  /** The first value of a named field anywhere in the request. */
  private static Optional<String> text(JsonNode request, String field) {
    return request.findValuesAsText(field).stream().filter(v -> !v.isBlank()).findFirst();
  }

  /** The user's question is the first text part of the A2A message. */
  private static String firstTextPart(JsonNode request) {
    return request.findValuesAsText("text").stream().findFirst().orElse("");
  }

  private static RawValue raw(JsonNode id) {
    return new RawValue(id.isMissingNode() ? "\"1\"" : id.toString());
  }
}
