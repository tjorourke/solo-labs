package io.solo.demo;

import java.util.List;

/**
 * The demo's output, in one place, so the agent code is not littered with printing.
 */
final class Console {

  private Console() {}

  static void tools(List<String> names) {
    line();
    say("tools the gateway handed this Java agent: %d".formatted(names.size()));
    names.forEach(name -> say("    - " + name));
    line();
  }

  static void asking(String prompt) {
    say("asking: " + prompt);
    line();
  }

  static void toolCalls(List<String> names) {
    for (var i = 0; i < names.size(); i++) {
      say("tool call %d: %s".formatted(i + 1, names.get(i)));
    }
    line();
    say("model tool calls: " + names.size());
    line();
  }

  static void answer(String text) {
    System.out.println(text);
  }

  static void serving(int port) {
    say("A2A server listening on :%d (card at /.well-known/agent-card.json)".formatted(port));
  }

  static void turn(int number, String prompt) {
    say("turn %d: %s".formatted(number, prompt));
  }

  static void failed(String message) {
    say("! " + message);
  }

  private static void say(String message) {
    System.out.println("  " + message);
  }

  private static void line() {
    System.out.println();
  }
}
