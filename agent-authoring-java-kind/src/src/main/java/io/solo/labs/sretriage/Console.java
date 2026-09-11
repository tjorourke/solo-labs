package io.solo.labs.sretriage;

/** The agent's log lines, in one place, so the logic has no printing in it. */
final class Console {

  private Console() {}

  static void serving(int port) {
    say("A2A server listening on :%d (card at /.well-known/agent-card.json)".formatted(port));
  }

  static void turn(int number, String userId, String prompt) {
    say("turn %d for %s: %s".formatted(number, userId, prompt));
  }

  static void tracing(String endpoint, String service) {
    say("tracing to %s as %s".formatted(endpoint, service));
  }

  static void failed(String message) {
    say("! " + message);
  }

  private static void say(String message) {
    System.out.println("  " + message);
  }
}
