package io.solo.labs.sretriage;

import com.google.adk.tools.mcp.StreamableHttpServerParameters;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Optional;

/**
 * Everything the agent is told about the world, read once from the environment.
 *
 * kagent injects KAGENT_NAME, KAGENT_NAMESPACE, KAGENT_URL and the OTEL_* variables into
 * every agent pod. The Agent record adds MODEL_NAME, MODEL_PROVIDER, MCP_SERVERS_CONFIG
 * and the model key. Nothing here is a credential for the tool server: the gateway
 * holds those.
 */
record Config(
    String agentName,
    String mcpUrl,
    String anthropicApiKey,
    String modelName,
    String instruction,
    int port) {

  private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(30);
  private static final Duration READ_TIMEOUT = Duration.ofSeconds(120);

  static Config fromEnvironment() {
    return new Config(
        env("KAGENT_NAME").orElse("sre-java"),
        mcpUrlFromEnvironment(),
        required("ANTHROPIC_API_KEY"),
        // MODEL_NAME is the variable kagent sets from the record. A fallback that reads
        // another name wins silently and runs a different model from the one declared.
        required("MODEL_NAME"),
        instructionResource(),
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

  /**
   * MCP_SERVERS_CONFIG is a JSON array of {name, type, url}, the same variable kagent's
   * Python runtime reads. The URL is the gateway, never the tool server itself.
   */
  private static String mcpUrlFromEnvironment() {
    return env("MCP_SERVERS_CONFIG")
        .flatMap(Json::firstUrl)
        .orElseThrow(() -> new IllegalStateException(
            "MCP_SERVERS_CONFIG must name at least one MCP server"));
  }

  /** The system prompt, packaged with the jar as a resource. */
  private static String instructionResource() {
    try (var in = Config.class.getResourceAsStream("/instruction.txt")) {
      if (in == null) {
        throw new IllegalStateException("instruction.txt is missing from the jar");
      }
      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    } catch (IOException e) {
      throw new IllegalStateException("cannot read instruction.txt", e);
    }
  }

  private static Optional<String> env(String name) {
    return Optional.ofNullable(System.getenv(name)).filter(v -> !v.isBlank());
  }

  private static String required(String name) {
    return env(name).orElseThrow(() -> new IllegalStateException("set " + name));
  }
}
