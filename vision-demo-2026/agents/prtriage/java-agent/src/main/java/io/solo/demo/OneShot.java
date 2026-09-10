package io.solo.demo;

import com.google.adk.agents.LlmAgent;
import com.google.adk.events.Event;
import com.google.adk.tools.BaseTool;
import com.google.adk.tools.mcp.McpToolset;
import com.google.genai.types.FunctionCall;

import java.util.List;

/**
 * Ask once, print what it cost, exit. This is the shape used from the notebook and from
 * {@code make run}, because the numbers are the demo: how many tools the gateway offered,
 * and how many round trips the model needed.
 */
final class OneShot {

  private final LlmAgent agent;
  private final McpToolset gateway;

  OneShot(LlmAgent agent, McpToolset gateway) {
    this.agent = agent;
    this.gateway = gateway;
  }

  void report(String prompt) {
    var offered = gateway.getTools(null).toList().blockingGet();
    Console.tools(offered.stream().map(BaseTool::name).toList());

    Console.asking(prompt);
    var events = Turn.of(agent, "prtriage-java").ask(prompt);

    Console.toolCalls(toolCalls(events));
    Console.answer(Turn.finalText(events));
  }

  private static List<String> toolCalls(List<Event> events) {
    return events.stream()
        .flatMap(event -> event.content().stream())
        .flatMap(content -> content.parts().stream())
        .flatMap(List::stream)
        .flatMap(part -> part.functionCall().stream())
        .map(call -> call.name().orElse("unnamed"))
        .toList();
  }
}
