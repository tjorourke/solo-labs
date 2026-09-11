package io.solo.demo;

import com.google.adk.tools.mcp.StreamableHttpServerParameters;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Optional;

/**
 * Everything this agent is told about the world, and note what is missing from it:
 * there is no GitHub credential. agentgateway holds that, so the agent is handed a
 * plain URL and nothing else.
 */
record Config(
    String mcpUrl,
    String anthropicApiKey,
    String anthropicBaseUrl,
    String modelName,
    String repository,
    Path skill,
    boolean serve,
    int port) {

  private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(30);
  private static final Duration READ_TIMEOUT = Duration.ofSeconds(120);

  static Config fromEnvironment() {
    return new Config(
        resolveMcpUrl(),
        required("ANTHROPIC_API_KEY"),
        // Empty means "straight to api.anthropic.com". Set, it is the in-cluster name of
        // the gateway that fronts the model, which is what lets egress be closed.
        env("ANTHROPIC_BASE_URL").orElse(""),
        // kagent injects MODEL_NAME, from the Agent record's modelName. Reading MODEL
        // meant the fallback won every time and the record was decorative: the agent ran
        // haiku while the catalogue said sonnet, and nothing said so.
        env("MODEL_NAME").or(() -> env("MODEL")).orElse("claude-haiku-4-5"),
        env("DEMO_REPO").orElse("tjorourke/kagent"),
        Path.of(env("SKILL_PATH").orElse("/app/skill.md")),
        env("SERVE").map(Boolean::parseBoolean).orElse(false),
        env("PORT").map(Integer::parseInt).orElse(8080));
  }

  StreamableHttpServerParameters mcpEndpoint() {
    return StreamableHttpServerParameters.builder()
        .url(mcpUrl)
        .timeout(CONNECT_TIMEOUT)
        .readTimeout(READ_TIMEOUT)
        .terminateOnClose(true)
        .build();
  }

  String instruction() {
    try {
      return Files.exists(skill)
          ? Files.readString(skill)
          : "You report on the state of open pull requests in a GitHub repository.";
    } catch (Exception e) {
      throw new IllegalStateException("cannot read the approved skill at " + skill, e);
    }
  }

  String defaultPrompt() {
    return env("PROMPT").orElse(
        "Give me the release report for %s, all open pull requests.".formatted(repository));
  }

  /**
   * AgentRegistry wires an agent to its approved MCP servers by injecting
   * MCP_SERVERS_CONFIG, a JSON array of {name,type,url}. That is the same variable its
   * Python sibling is given, so this reads it rather than inventing a convention.
   * MCP_URL stays as a fallback for running outside the registry.
   */
  private static String resolveMcpUrl() {
    return env("MCP_SERVERS_CONFIG")
        .flatMap(Json::firstUrl)
        .or(() -> env("MCP_URL"))
        .orElseThrow(() -> new IllegalStateException(
            "set MCP_SERVERS_CONFIG or MCP_URL to the agentgateway MCP endpoint"));
  }

  private static Optional<String> env(String name) {
    return Optional.ofNullable(System.getenv(name)).filter(v -> !v.isBlank());
  }

  private static String required(String name) {
    return env(name).orElseThrow(() -> new IllegalStateException("set " + name));
  }
}
