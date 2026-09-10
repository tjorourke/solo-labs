package io.solo.demo;

import com.google.adk.agents.LlmAgent;
import com.google.adk.tools.BaseTool;
import com.google.adk.tools.mcp.McpToolset;

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

    Console.toolCalls(Turn.toolCalls(events).stream()
        .map(call -> call.name().orElse("unnamed"))
        .toList());
    Console.answer(Turn.finalText(events));
  }
}
