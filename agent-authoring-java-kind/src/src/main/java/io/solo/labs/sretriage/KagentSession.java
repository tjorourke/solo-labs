package io.solo.labs.sretriage;

import com.fasterxml.jackson.databind.node.ObjectNode;

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
 * Writes a finished turn into kagent's stores, which is what the UI reads.
 *
 * The controller passes the A2A exchange through to the agent and only ever reads from
 * its stores. The UI lists a conversation from {@code GET /api/sessions/{id}/tasks}, and
 * a task gets in there one way: the agent posts it. kagent's Python and Go runtimes do
 * this on the agent's behalf; a Java agent does it here.
 *
 * Both writes authenticate with the service-account token kagent projects into the pod
 * at {@code /var/run/secrets/tokens/kagent-token}, and carry the user the controller
 * named in the {@code X-user-id} request header, because the store is keyed by
 * (session, user).
 */
final class KagentSession {

  private static final Path TOKEN = Path.of("/var/run/secrets/tokens/kagent-token");
  private static final HttpClient HTTP = HttpClient.newBuilder()
      .connectTimeout(Duration.ofSeconds(10)).build();

  private KagentSession() {}

  /** True when this agent is running under kagent and can write to the stores. */
  static boolean available() {
    return System.getenv("KAGENT_URL") != null && Files.isReadable(TOKEN);
  }

  /** An invocation id in kagent's own shape. One per turn, shared by everything in it. */
  static String newInvocationId() {
    return "e-" + UUID.randomUUID();
  }

  /**
   * {@code POST /api/tasks}: the A2A Task for the turn, whose {@code contextId} is the
   * session and whose {@code history} runs from the user's question to the agent's
   * answer. The UI draws the history, so a task with a perfect artifact and no history
   * renders as nothing.
   */
  static void recordTask(String sessionId, String userId, ObjectNode task) {
    if (!available() || sessionId == null || sessionId.isBlank()) {
      return;
    }
    var uri = URI.create("%s/api/tasks?user_id=%s".formatted(
        System.getenv("KAGENT_URL"), URLEncoder.encode(userId, StandardCharsets.UTF_8)));
    post(uri, userId, Json.write(task), "task store");
  }

  /**
   * {@code POST /api/sessions/{id}/events}: one ADK event, for the session's own record.
   * {@code data} is a string containing the event's JSON, not an object.
   *
   * The event is an ADK event in the shape kagent's own runtime writes. The fields that
   * matter: {@code timestamp} in epoch seconds as a float (it orders the conversation),
   * {@code invocation_id} shared by both events of a turn, {@code partial} false, and a
   * part carrying its whole schema rather than only {@code text}.
   */
  static void recordEvent(String sessionId, String userId, String invocationId,
                          String author, String text) {
    if (!available() || sessionId == null || sessionId.isBlank()
        || userId == null || userId.isBlank()) {
      return;
    }
    var part = Json.object()
        .put("code_execution_result", (String) null)
        .put("executable_code", (String) null)
        .put("file_data", (String) null)
        .put("function_call", (String) null)
        .put("function_response", (String) null)
        .put("inline_data", (String) null)
        .put("media_resolution", (String) null)
        .put("text", text)
        .put("thought", (Boolean) null);
    var content = Json.object().put("role", "user".equals(author) ? "user" : "model");
    content.putArray("parts").add(part);

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
        .put("data", Json.write(event));

    var uri = URI.create("%s/api/sessions/%s/events?user_id=%s".formatted(
        System.getenv("KAGENT_URL"),
        URLEncoder.encode(sessionId, StandardCharsets.UTF_8),
        URLEncoder.encode(userId, StandardCharsets.UTF_8)));
    post(uri, userId, Json.write(body), author + " event");
  }

  /** One authenticated POST. A rejected write is logged, because nothing else reports it. */
  private static void post(URI uri, String userId, String body, String what) {
    try {
      var response = HTTP.send(HttpRequest.newBuilder(uri)
          .header("Authorization", "Bearer " + Files.readString(TOKEN).trim())
          .header("Content-Type", "application/json")
          .header("X-user-id", userId)
          .timeout(Duration.ofSeconds(20))
          .POST(HttpRequest.BodyPublishers.ofString(body))
          .build(), HttpResponse.BodyHandlers.ofString());
      if (response.statusCode() >= 300) {
        Console.failed("%s rejected: %d %s".formatted(what, response.statusCode(), response.body()));
      }
    } catch (Exception e) {
      Console.failed("could not write the %s: %s: %s".formatted(
          what, e.getClass().getSimpleName(), e.getMessage()));
    }
  }
}
