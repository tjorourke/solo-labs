package io.solo.labs.sretriage;

import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.google.adk.agents.LlmAgent;
import com.google.adk.models.Claude;
import com.google.adk.tools.Annotations;
import com.google.adk.tools.FunctionTool;
import com.google.adk.tools.mcp.McpToolset;

import java.util.Map;

/**
 * A Kubernetes SRE triage agent, in Java on Google ADK, hosted by kagent.
 *
 * Defines the model and tools. {@link A2aServer} handles A2A requests;
 * {@link KagentSession} writes completed turns to the controller.
 */
public final class SreTriage {

  static final String DESCRIPTION =
      "Kubernetes SRE triage. Reports which pods in a namespace are unhealthy, and why.";

  public static void main(String[] args) throws Exception {
    var config = Config.fromEnvironment();
    // Before the agent is built, so ADK's own spans have an exporter to go to.
    Telemetry.start(config.agentName());

    try (var tools = new McpToolset(config.mcpEndpoint())) {
      new A2aServer(agent(tools, config), config).start();
    }
  }

  /**
   * Creates the agent with the MCP tools allowed by the gateway and a local health tool.
   */
  static LlmAgent agent(McpToolset tools, Config config) {
    var anthropic = AnthropicOkHttpClient.builder().apiKey(config.anthropicApiKey()).build();
    return LlmAgent.builder()
        .name(config.agentName().replace('-', '_'))
        .description(DESCRIPTION)
        .model(new Claude(config.modelName(), anthropic))
        .instruction(config.instruction())
        // Wrapped so each call is reported the moment the model makes it. See Progress.
        .tools(Progress.wrap(tools), Progress.wrap(FunctionTool.create(SreTriage.class, "unhealthy")))
        .build();
  }

  /**
   * Evaluates pod health, allowing Pending pods a five-minute grace period.
   */
  @Annotations.Schema(description =
      "Apply the health gate to one pod: unhealthy when it is not Running, has restarted "
      + "more than three times, or has been Pending for more than five minutes.")
  public static Map<String, Object> unhealthy(
      @Annotations.Schema(name = "phase", description = "the pod phase, e.g. Running or Pending") String phase,
      @Annotations.Schema(name = "restarts", description = "container restart count") Integer restarts,
      @Annotations.Schema(name = "pendingMinutes", description = "minutes the pod has been Pending, 0 if not Pending") Integer pendingMinutes) {
    int pending = pendingMinutes == null ? 0 : pendingMinutes;
    int restarted = restarts == null ? 0 : restarts;
    if ("Pending".equals(phase)) {
      return pending > 5
          ? verdict(true, "Pending for " + pending + " minutes, more than five")
          : verdict(false, "Pending for " + pending + " minutes, within the five minute allowance");
    }
    if (!"Running".equals(phase)) {
      return verdict(true, "phase is " + phase + ", not Running");
    }
    if (restarted > 3) {
      return verdict(true, restarted + " restarts, more than three");
    }
    return verdict(false, "Running with three or fewer restarts");
  }

  /** The tool's result: the verdict and the clause of the rule that decided it. */
  private static Map<String, Object> verdict(boolean unhealthy, String reason) {
    return Map.of("unhealthy", unhealthy, "reason", reason);
  }
}
