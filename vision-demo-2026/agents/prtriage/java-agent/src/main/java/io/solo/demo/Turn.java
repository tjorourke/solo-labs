package io.solo.demo;

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

/** One question through an ADK runner. The events come back together; the tool calls are reported as they happen. */
record Turn(InMemoryRunner runner, String appName) {

  static Turn of(BaseAgent agent, String appName) {
    return new Turn(new InMemoryRunner(agent, appName), appName);
  }

  List<Event> ask(String prompt) {
    return ask(prompt, call -> {});
  }

  /**
   * The same turn, telling {@code onToolCall} about each tool call when the model makes
   * it and again when its result is back. The events themselves still arrive at the end:
   * they are what the stored task is built from, and the progress is a separate channel.
   */
  List<Event> ask(String prompt, Consumer<Progress.ToolEvent> onToolCall) {
    // Map.<String, Object>of() rather than null: null binds to the deprecated
    // ConcurrentMap overload, and a deprecation warning is not what you want on screen.
    var session = runner.sessionService()
        .createSession(appName, "demo", Map.<String, Object>of(), null)
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

  /** The function calls the model made, in order, as {name, args, id} triples. */
  static List<FunctionCall> toolCalls(List<Event> events) {
    return events.stream()
        .flatMap(event -> event.content().stream())
        .flatMap(content -> content.parts().stream())
        .flatMap(List::stream)
        .flatMap(part -> part.functionCall().stream())
        .toList();
  }

  /**
   * The tool RESPONSES, which are the interesting half: this is the payload that
   * crossed the model's context window on the way to the answer. Without them an A2A
   * client can see what was called but not what it cost.
   */
  static List<FunctionResponse> toolResponses(List<Event> events) {
    return events.stream()
        .flatMap(event -> event.content().stream())
        .flatMap(content -> content.parts().stream())
        .flatMap(List::stream)
        .flatMap(part -> part.functionResponse().stream())
        .toList();
  }

  static String finalText(List<Event> events) {
    return events.stream()
        .filter(Event::finalResponse)
        .map(Event::stringifyContent)
        .reduce("", String::concat);
  }
}
