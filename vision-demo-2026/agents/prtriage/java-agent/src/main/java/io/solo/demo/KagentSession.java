package io.solo.demo;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.UUID;

/**
 * Writes a turn into kagent's session store, which is the only thing the UI reads.
 *
 * WHY A BYO AGENT HAS TO DO THIS
 * Answering A2A correctly is not enough to appear in the kagent UI. The UI does not draw
 * the conversation from the stream it just received: it draws it from the events the
 * controller has stored against that session. kagent's own Python runtime writes those
 * as a side effect of running the agent, so a Python agent gets it for free and a BYO
 * agent gets an empty chat, a spinner that never resolves, and no history on return.
 *
 * The contract, established against the running controller rather than from docs:
 *
 *   POST {KAGENT_URL}/api/sessions/{sessionId}/events?user_id={userId}
 *   Authorization: Bearer <the projected token at /var/run/secrets/tokens/kagent-token>
 *   {"id": "<uuid>", "data": "<the event, as a JSON STRING>"}
 *
 * The nesting is the part that bites: `data` is a string containing JSON, not an object.
 * Post the event object directly and the call succeeds, returns the row, and stores an
 * empty body, so the chat stays blank and nothing anywhere reports a problem.
 */
final class KagentSession {

  private static final Path TOKEN = Path.of("/var/run/secrets/tokens/kagent-token");
  private static final HttpClient HTTP = HttpClient.newBuilder()
      .connectTimeout(Duration.ofSeconds(10)).build();

  private KagentSession() {}

  /** True when this agent is running under kagent and can write to the session store. */
  static boolean available() {
    return System.getenv("KAGENT_URL") != null && Files.isReadable(TOKEN);
  }

  /**
   * Record one message. author is "user" for the prompt, or the agent's name for the
   * answer; kagent renders anything that is not "user" as the agent side.
   */
  /** An invocation id in kagent's own shape. One per turn, shared by both events. */
  static String newInvocationId() {
    return "e-" + UUID.randomUUID();
  }

  static void record(String sessionId, String userId, String invocationId,
                     String author, String text) {
    if (!available() || sessionId == null || sessionId.isBlank()
        || userId == null || userId.isBlank()) {
      return;
    }
    try {
      // The stored event is an ADK event and the UI reads specific fields off it. Match
      // the shape kagent's own runtime writes, because a nearly-right event is accepted,
      // stored, and silently not rendered: the answer appears live from the stream and
      // the conversation is empty the moment you navigate back.
      //
      // The ones that are not decoration:
      //   id, timestamp   epoch seconds as a FLOAT, which orders the conversation
      //   invocation_id   "e-" prefixed, and the SAME for both events of one turn
      //   partial         false, not null. A null here reads as "not a settled message"
      //   actions         present, with its empty maps rather than omitted
      var content = Json.object().put("role", "user".equals(author) ? "user" : "model");
      content.putArray("parts").add(Json.object().put("text", text));

      var actions = Json.object()
          .put("skip_summarization", (Boolean) null)
          .put("transfer_to_agent", (String) null)
          .put("escalate", (Boolean) null);
      actions.putObject("state_delta");
      actions.putObject("artifact_delta");
      actions.putObject("requested_auth_configs");
      actions.putObject("requested_tool_confirmations");

      var event = Json.object()
          .put("id", UUID.randomUUID().toString())
          .put("timestamp", System.currentTimeMillis() / 1000.0)
          .put("author", author)
          .put("invocation_id", invocationId)
          .put("branch", (String) null)
          .put("partial", false)
          .put("turn_complete", (Boolean) null)
          .put("error_code", (String) null)
          .put("error_message", (String) null)
          .put("interrupted", (Boolean) null);
      if (!"user".equals(author)) {
        event.put("finish_reason", "STOP");
      }
      event.set("content", content);
      event.set("actions", actions);

      var body = Json.object()
          .put("id", UUID.randomUUID().toString())
          .put("data", Json.write(event));        // a STRING, deliberately

      var uri = URI.create("%s/api/sessions/%s/events?user_id=%s".formatted(
          System.getenv("KAGENT_URL"),
          URLEncoder.encode(sessionId, StandardCharsets.UTF_8),
          URLEncoder.encode(userId, StandardCharsets.UTF_8)));

      var response = HTTP.send(HttpRequest.newBuilder(uri)
          .header("Authorization", "Bearer " + Files.readString(TOKEN).trim())
          .header("Content-Type", "application/json")
          .timeout(Duration.ofSeconds(20))
          .POST(HttpRequest.BodyPublishers.ofString(Json.write(body)))
          .build(), HttpResponse.BodyHandlers.ofString());

      // Say so when it fails. A silent failure here is invisible until someone opens the
      // UI and finds an empty conversation, which is how this cost an afternoon.
      if (response.statusCode() >= 300) {
        Console.failed("session store rejected the %s event: %d %s"
            .formatted(author, response.statusCode(), response.body()));
      }
    } catch (Exception e) {
      Console.failed("could not write to the session store: " + e);
    }
  }
}
