package io.solo.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.util.Optional;

/** Jackson comes in with ADK, so there is no reason to parse JSON by hand. */
final class Json {

  static final ObjectMapper MAPPER = new ObjectMapper();

  private Json() {}

  static JsonNode parse(String body) {
    try {
      return MAPPER.readTree(body);
    } catch (Exception e) {
      throw new IllegalArgumentException("not JSON", e);
    }
  }

  static String write(ObjectNode node) {
    try {
      return MAPPER.writeValueAsString(node);
    } catch (Exception e) {
      throw new IllegalStateException("cannot serialise the response", e);
    }
  }

  static ObjectNode object() {
    return MAPPER.createObjectNode();
  }

  /** The first "url" anywhere in the document, which is how MCP_SERVERS_CONFIG is read. */
  static Optional<String> firstUrl(String json) {
    return Optional.of(parse(json).findValuesAsText("url"))
        .filter(urls -> !urls.isEmpty())
        .map(urls -> urls.get(0));
  }
}
