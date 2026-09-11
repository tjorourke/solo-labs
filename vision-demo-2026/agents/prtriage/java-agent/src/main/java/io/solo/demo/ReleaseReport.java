package io.solo.demo;

import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.google.adk.agents.Instruction;
import com.google.adk.agents.LlmAgent;
import com.google.adk.models.Claude;
import com.google.adk.tools.Annotations;
import com.google.adk.tools.FunctionTool;
import com.google.adk.tools.mcp.McpToolset;
import io.reactivex.rxjava3.core.Single;

import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.Map;

/**
 * The release report agent, in Java, on Google ADK, through agentgateway.
 *
 * The point of this class is how little is in it. It does not know how many tools the
 * gateway is offering, whether the catalogue has been collapsed into a single
 * {@code run_code} tool, or which operations the gateway is refusing to expose. Those
 * are properties of the gateway, so flipping any of them needs no change here and no
 * rebuild.
 */
public final class ReleaseReport {

  private static final String DESCRIPTION =
      "Reports which open pull requests are ready to merge and which are blocked.";

  public static void main(String[] args) throws Exception {
    var config = Config.fromEnvironment();
    // Before the agent is built, so ADK's own spans have somewhere to go.
    Telemetry.start(System.getenv().getOrDefault("KAGENT_NAME", "prtriage-java"));

    try (var gateway = new McpToolset(config.mcpEndpoint())) {
      var agent = agent(gateway, config);

      if (config.serve()) {
        new A2aServer(agent, DESCRIPTION).start(config.port());
      } else {
        new OneShot(agent, gateway).report(config.defaultPrompt());
      }
    }
  }

  /**
   * The whole integration. One toolset from the gateway, one local tool for the date,
   * and no credential for anything the gateway fronts.
   */
  private static LlmAgent agent(McpToolset gateway, Config config) {
    var anthropicBuilder = AnthropicOkHttpClient.builder().apiKey(config.anthropicApiKey());
    // Through the gateway when there is one, so the agent needs no route to the internet.
    if (!config.anthropicBaseUrl().isBlank()) {
      anthropicBuilder.baseUrl(config.anthropicBaseUrl());
    }
    var anthropic = anthropicBuilder.build();
    var skill = config.instruction();

    return LlmAgent.builder()
        .name("prtriage_java")
        .description(DESCRIPTION)
        .model(new Claude(config.modelName(), anthropic))
        // An Instruction.Provider is evaluated per turn, so the date is right on a pod
        // that has been up for a week. A plain instruction() string is fixed at
        // startup, and a report headed with the wrong date is wrong in the one place
        // everybody reads.
        .instruction(new Instruction.Provider(ctx -> Single.just(skill + dateNote())))
        .tools(gateway, FunctionTool.create(ReleaseReport.class, "today"))
        .build();
  }

  private static String dateNote() {
    return "\n\nToday is %s (UTC). Date the report with it."
        .formatted(LocalDate.now(ZoneOffset.UTC));
  }

  /**
   * The only local tool, and the same one its Python sibling has, for the same reason:
   * the gateway's code sandbox deliberately has no clock, so a program running in there
   * cannot work out the date. Without this the model invents one, and it invents it
   * wrong.
   */
  @Annotations.Schema(description = "Return today's date as YYYY-MM-DD in UTC.")
  public static Map<String, String> today() {
    return Map.of("today", LocalDate.now(ZoneOffset.UTC).toString());
  }
}
