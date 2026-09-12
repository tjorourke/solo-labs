package io.solo.labs.sretriage;

import com.google.adk.agents.BaseAgent;
import com.google.adk.agents.RunConfig;
import com.google.adk.events.Event;
import com.google.adk.runner.InMemoryRunner;
import com.google.genai.types.Content;
import com.google.genai.types.FunctionCall;
import com.google.genai.types.FunctionResponse;
import com.google.genai.types.Part;

import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * One question through an ADK runner.
 *
 * ADK hands the turn's events over when the turn finishes, so the events are collected
 * and read at the end. Tool calls are reported as they happen through {@link Progress},
 * which is a separate channel from the events.
 */
record Turn(InMemoryRunner runner, String appName) {

  static Turn of(BaseAgent agent, String appName) {
    // Each question starts independently. Saved kagent conversation history is
    // kept for the UI and is not loaded into this runner.
    return new Turn(new InMemoryRunner(agent, appName), appName);
  }

  /**
   * Runs the prompt in a fresh ADK session, telling {@code onToolCall} about each tool
   * call when the model makes it and again when its result is back.
   */
  List<Event> ask(String prompt, Consumer<Progress.ToolEvent> onToolCall) {
    // Map.<String, Object>of() rather than null: null binds to the deprecated
    // ConcurrentMap overload.
    var session = runner.sessionService()
        .createSession(appName, "kagent", Map.<String, Object>of(), null)
        .blockingGet();
    Progress.watch(session.id(), onToolCall);
    try {
      return runner.runAsync(
              session.userId(),
              session.id(),
              Content.fromParts(Part.fromText(prompt)),
              RunConfig.builder().build())
          .toList()
          .blockingGet();
    } finally {
      Progress.unwatch(session.id());
    }
  }

  /** The function calls the model made, in order. */
  static List<FunctionCall> toolCalls(List<Event> events) {
    return events.stream()
        .flatMap(event -> event.content().stream())
        .flatMap(content -> content.parts().stream())
        .flatMap(List::stream)
        .flatMap(part -> part.functionCall().stream())
        .toList();
  }

  /** The tool responses, which are the payload that crossed the model's context. */
  static List<FunctionResponse> toolResponses(List<Event> events) {
    return events.stream()
        .flatMap(event -> event.content().stream())
        .flatMap(content -> content.parts().stream())
        .flatMap(List::stream)
        .flatMap(part -> part.functionResponse().stream())
        .toList();
  }

  /** The model's final answer: the text of the events ADK marks as the final response. */
  static String finalText(List<Event> events) {
    return events.stream()
        .filter(Event::finalResponse)
        .map(Event::stringifyContent)
        .reduce("", String::concat);
  }
}
