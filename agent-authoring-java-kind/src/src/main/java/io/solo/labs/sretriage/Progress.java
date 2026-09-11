package io.solo.labs.sretriage;

import com.google.adk.agents.ReadonlyContext;
import com.google.adk.tools.BaseTool;
import com.google.adk.tools.BaseToolset;
import com.google.adk.tools.ToolContext;
import com.google.genai.types.FunctionDeclaration;
import io.reactivex.rxjava3.core.Flowable;
import io.reactivex.rxjava3.core.Single;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;

/**
 * Tool calls as they happen, for whoever is watching the turn.
 *
 * ADK hands over the events of a step when the step finishes, so anything reading the
 * event stream learns of a tool call only once its result is back. Wrapping the tools
 * themselves gives the moment the model asked for one, which is what a progress line in
 * a terminal, or a tool card in a chat, is about. Nothing else changes: the declaration
 * the model sees and the result it gets are the inner tool's.
 */
final class Progress {

  /** One tool call. {@code response} is null while the call is still in flight. */
  record ToolEvent(String name, String id, Map<String, Object> args, Map<String, Object> response) {}

  // Keyed by the ADK session, which Turn creates fresh per question, so two questions
  // being answered at once on the server's thread pool never see each other's calls.
  private static final ConcurrentHashMap<String, Consumer<ToolEvent>> LISTENERS = new ConcurrentHashMap<>();

  private Progress() {}

  static void watch(String sessionId, Consumer<ToolEvent> listener) {
    LISTENERS.put(sessionId, listener);
  }

  static void unwatch(String sessionId) {
    LISTENERS.remove(sessionId);
  }

  static BaseToolset wrap(BaseToolset inner) {
    return new BaseToolset() {
      @Override
      public Flowable<BaseTool> getTools(ReadonlyContext context) {
        return inner.getTools(context).map(tool -> wrap(tool));
      }

      @Override
      public void close() throws Exception {
        inner.close();
      }
    };
  }

  static BaseTool wrap(BaseTool inner) {
    return inner instanceof Watched ? inner : new Watched(inner);
  }

  private static final class Watched extends BaseTool {
    private final BaseTool inner;

    Watched(BaseTool inner) {
      super(inner.name(), inner.description(), inner.longRunning());
      this.inner = inner;
    }

    @Override
    public Optional<FunctionDeclaration> declaration() {
      return inner.declaration();
    }

    @Override
    public Single<Map<String, Object>> runAsync(Map<String, Object> args, ToolContext toolContext) {
      var listener = LISTENERS.get(toolContext.invocationContext().session().id());
      if (listener == null) {
        return inner.runAsync(args, toolContext);
      }
      var id = toolContext.functionCallId().orElse("");
      listener.accept(new ToolEvent(name(), id, args, null));
      return inner.runAsync(args, toolContext)
          .doOnSuccess(response -> listener.accept(new ToolEvent(name(), id, args, response)));
    }
  }
}
