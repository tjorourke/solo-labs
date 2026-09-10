package io.solo.demo;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.google.adk.agents.LlmAgent;
import com.google.adk.agents.RunConfig;
import com.google.adk.events.Event;
import com.google.adk.models.Claude;
import com.google.adk.runner.InMemoryRunner;
import com.google.adk.sessions.Session;
import com.google.adk.tools.Annotations;
import com.google.adk.tools.BaseTool;
import com.google.adk.tools.FunctionTool;
import com.google.adk.tools.mcp.McpToolset;
import com.google.adk.tools.mcp.StreamableHttpServerParameters;
import com.google.genai.types.Content;
import com.google.genai.types.Part;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;

/**
 * The same release report, in Java, on the same Google ADK, through the same
 * agentgateway endpoint as the Python agent.
 *
 * Nothing here knows how many tools it is being given, whether the catalogue was
 * collapsed into run_code, or which operations the gateway is refusing. That is the
 * argument: the tool layer is not the agent's problem, and it is not the agent
 * language's problem either.
 *
 * Env:
 *   MCP_URL            the agentgateway MCP endpoint (no credential of any kind)
 *   ANTHROPIC_API_KEY  the model
 *   DEMO_REPO          owner/name of the repository to report on
 *   PROMPT             overrides the question
 *   SKILL_PATH         the approved skill, mounted or baked in (default /app/skill.md)
 */
public final class ReleaseReport {

  public static void main(String[] args) throws Exception {
    String mcpUrl = mcpUrlFromEnv();
    String apiKey = env("ANTHROPIC_API_KEY", null);
    String repo = env("DEMO_REPO", "tjorourke/kagent");
    String skillPath = env("SKILL_PATH", "/app/skill.md");
    String prompt = env("PROMPT",
        "Give me the release report for " + repo + ", all open pull requests.");

    // The endpoint carries no credential. agentgateway injects the GitHub token
    // upstream from a Secret this process cannot read and does not need.
    StreamableHttpServerParameters mcp = StreamableHttpServerParameters.builder()
        .url(mcpUrl)
        .timeout(Duration.ofSeconds(30))
        .readTimeout(Duration.ofSeconds(120))
        .terminateOnClose(true)
        .build();

    try (McpToolset toolset = new McpToolset(mcp)) {

      // Beat 1 and beat 5, from Java: how many tools did the gateway just hand us?
      List<BaseTool> tools = toolset.getTools(null).toList().blockingGet();
      System.out.println();
      System.out.println("  tools the gateway handed this Java agent: " + tools.size());
      for (BaseTool t : tools) {
        System.out.println("    - " + t.name());
      }
      System.out.println();

      String instruction = Files.exists(Path.of(skillPath))
          ? Files.readString(Path.of(skillPath))
          : "You report on the state of open pull requests in a GitHub repository.";

      AnthropicClient anthropic = AnthropicOkHttpClient.builder().apiKey(apiKey).build();
      Claude model = new Claude(env("MODEL", "claude-haiku-4-5"), anthropic);

      LlmAgent agent = LlmAgent.builder()
          .name("prtriage_java")
          .description("Reports which open pull requests are ready to merge and which are blocked.")
          .model(model)
          .instruction(instruction)
          .tools(toolset, FunctionTool.create(ReleaseReport.class, "today"))
          .build();

      InMemoryRunner runner = new InMemoryRunner(agent, "prtriage-java");
      Session session = runner.sessionService()
          .createSession("prtriage-java", "demo", null, null)
          .blockingGet();

      System.out.println("  asking: " + prompt);
      System.out.println();

      Content question = Content.fromParts(Part.fromText(prompt));
      List<Event> events = runner
          .runAsync(session.userId(), session.id(), question, RunConfig.builder().build())
          .toList()
          .blockingGet();

      int toolCalls = 0;
      for (Event e : events) {
        if (e.content().isPresent() && e.content().get().parts().isPresent()) {
          for (Part p : e.content().get().parts().get()) {
            if (p.functionCall().isPresent()) {
              toolCalls++;
              System.out.println("  tool call " + toolCalls + ": "
                  + p.functionCall().get().name().orElse("?"));
            }
          }
        }
      }

      System.out.println();
      System.out.println("  model tool calls: " + toolCalls);
      System.out.println();
      for (Event e : events) {
        if (e.finalResponse()) {
          System.out.println(e.stringifyContent());
        }
      }
    }
  }

  /**
   * AgentRegistry wires an agent to its approved MCP servers by injecting
   * MCP_SERVERS_CONFIG, a JSON array of {name,type,url}. That is the same variable the
   * Python agent is given, so the Java one reads it rather than inventing its own
   * convention. MCP_URL stays as a fallback for running this outside the registry.
   */
  /**
   * The one local tool this agent has, and the same one its Python sibling has, for the
   * same reason: the gateway's code sandbox deliberately has no clock, so a program in
   * there cannot work out today's date. Without this the model invents one, and it
   * invents it wrong.
   */
  @Annotations.Schema(description = "Return today's date as YYYY-MM-DD in UTC.")
  public static Map<String, String> today() {
    return Map.of("today", LocalDate.now(ZoneOffset.UTC).toString());
  }

  private static String mcpUrlFromEnv() {
    String cfg = System.getenv("MCP_SERVERS_CONFIG");
    if (cfg != null && !cfg.isBlank()) {
      java.util.regex.Matcher m =
          java.util.regex.Pattern.compile("\"url\"\\s*:\\s*\"([^\"]+)\"").matcher(cfg);
      if (m.find()) {
        return m.group(1);
      }
    }
    return env("MCP_URL", null);
  }

  private static String env(String name, String fallback) {
    String v = System.getenv(name);
    if (v == null || v.isBlank()) {
      if (fallback == null) {
        throw new IllegalStateException("set " + name);
      }
      return fallback;
    }
    return v;
  }
}
