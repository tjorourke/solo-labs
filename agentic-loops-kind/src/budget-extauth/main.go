// budget-extauth — Envoy ext_authz gRPC service that enforces per-session
// runaway containment budgets for the agentic-loops-kind lab.
//
// Five counters, all keyed by the MCP session id (Mcp-Session-Id header):
//
//   max_tool_calls   — total tools/call requests per session.
//                       INCR tool_calls:<sid> on every tools/call;
//                       deny if > limit.
//   max_turns        — bumped when the inspector UI sends a new value in
//                       the X-Goal-Turn header. The header is the trust-
//                       boundary signal; in production this would come
//                       from the orchestrator. INCR turns:<sid> on each
//                       new turn value; deny if > limit.
//   max_chain_depth  — consecutive tools/call without a new turn.
//                       SET   chain_depth:<sid> = N+1 on each call;
//                       reset to 0 when a new turn header arrives.
//                       deny if > limit.
//   repetition       — same (tool_name, args_hash) repeated within a
//                       recent window. LPUSH+LTRIM recent_calls:<sid>;
//                       count duplicates; deny if any.
//
// (max_tokens belongs in agentic-budgets-kind — referenced from the story
// page rather than re-implemented here.)
//
// Deny response body is structured JSON: {reason_code, limit, observed,
// session, tool, controlled_cutoff: true}. That's the "deterministic
// cut-off with a controlled outcome" the customer ask requires — the
// agent can parse it and react.
//
// Other MCP methods (initialize, notifications/initialized, tools/list)
// pass through without counting.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	authpb "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/redis/go-redis/v9"
	rpcstatus "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"gopkg.in/yaml.v3"
)

// ─── budget config ──────────────────────────────────────────────────────────

type budgets struct {
	MaxToolCalls       int `yaml:"maxToolCalls"`
	MaxTurns           int `yaml:"maxTurns"`
	MaxChainDepth      int `yaml:"maxChainDepth"`
	RepetitionWindow   int `yaml:"repetitionWindow"`   // how many recent calls to scan
	RepetitionMaxDups  int `yaml:"repetitionMaxDups"`  // 1 = deny on first duplicate in window
	SessionTTLSec      int `yaml:"sessionTTLSec"`      // counters expire after this many seconds of inactivity
}

type budgetStore struct {
	mu   sync.RWMutex
	path string
	last budgets
}

func (b *budgetStore) reload() {
	raw, err := os.ReadFile(b.path)
	if err != nil {
		log.Printf("budgets reload: read %s: %v", b.path, err)
		return
	}
	var next budgets
	if err := yaml.Unmarshal(raw, &next); err != nil {
		log.Printf("budgets reload: parse: %v", err)
		return
	}
	// Defaults for any unset field.
	if next.MaxToolCalls == 0 {
		next.MaxToolCalls = 10
	}
	if next.MaxTurns == 0 {
		next.MaxTurns = 5
	}
	if next.MaxChainDepth == 0 {
		next.MaxChainDepth = 4
	}
	if next.RepetitionWindow == 0 {
		next.RepetitionWindow = 3
	}
	if next.RepetitionMaxDups == 0 {
		next.RepetitionMaxDups = 1
	}
	if next.SessionTTLSec == 0 {
		next.SessionTTLSec = 600
	}
	b.mu.Lock()
	b.last = next
	b.mu.Unlock()
}

func (b *budgetStore) get() budgets {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.last
}

// ─── ext-auth server ────────────────────────────────────────────────────────

type authServer struct {
	authpb.UnimplementedAuthorizationServer
	store *budgetStore
	rdb   *redis.Client
}

func (s *authServer) Check(ctx context.Context, req *authpb.CheckRequest) (*authpb.CheckResponse, error) {
	s.store.reload()
	b := s.store.get()

	httpAttr := req.GetAttributes().GetRequest().GetHttp()
	headers := httpAttr.GetHeaders()
	body := httpAttr.GetBody()
	method := httpAttr.GetMethod()

	// Only POSTs with bodies are MCP JSON-RPC. Anything else, allow.
	if method != "POST" || body == "" {
		return allow(), nil
	}

	var rpc struct {
		Method string `json:"method"`
		Params struct {
			Name      string                 `json:"name"`
			Arguments map[string]interface{} `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(body), &rpc); err != nil {
		// Not JSON — let upstream decide.
		return allow(), nil
	}

	// Only tools/call is interesting. initialize / notifications/initialized
	// / tools/list / ping pass through uncounted.
	if rpc.Method != "tools/call" || rpc.Params.Name == "" {
		return allow(), nil
	}

	sessionID := lookupHeader(headers, "mcp-session-id")
	if sessionID == "" {
		// No session header — can't track state. Allow but warn.
		log.Printf("WARN: tools/call without Mcp-Session-Id — runaway counters skipped")
		return allow(), nil
	}

	toolName := rpc.Params.Name
	ttl := time.Duration(b.SessionTTLSec) * time.Second

	// ── (A) Turn tracking ────────────────────────────────────────────────
	// The inspector UI sets X-Goal-Turn: <integer> to signal a new "agent
	// goal" turn. When the value changes (or is the first time we see one),
	// bump turns and reset chain_depth.
	rawTurn := lookupHeader(headers, "x-goal-turn")
	if rawTurn != "" {
		if newTurn, err := strconv.Atoi(strings.TrimSpace(rawTurn)); err == nil {
			prevTurn, _ := s.rdb.Get(ctx, "last_turn:"+sessionID).Int()
			if newTurn != prevTurn {
				// New turn — increment + reset chain depth.
				_ = s.rdb.Set(ctx, "last_turn:"+sessionID, newTurn, ttl).Err()
				turns, err := s.rdb.Incr(ctx, "turns:"+sessionID).Result()
				if err == nil {
					_ = s.rdb.Expire(ctx, "turns:"+sessionID, ttl).Err()
				}
				_ = s.rdb.Set(ctx, "chain_depth:"+sessionID, 0, ttl).Err()
				if turns > int64(b.MaxTurns) {
					return denyJSON(typev3.StatusCode_TooManyRequests, denyBody{
						ReasonCode:       "max_turns_exceeded",
						Limit:            b.MaxTurns,
						Observed:         int(turns),
						Session:          sessionID,
						Tool:             toolName,
						ControlledCutoff: true,
					}), nil
				}
			}
		}
	}

	// ── (B) Tool-call count ──────────────────────────────────────────────
	calls, err := s.rdb.Incr(ctx, "tool_calls:"+sessionID).Result()
	if err == nil {
		_ = s.rdb.Expire(ctx, "tool_calls:"+sessionID, ttl).Err()
	}
	if calls > int64(b.MaxToolCalls) {
		return denyJSON(typev3.StatusCode_TooManyRequests, denyBody{
			ReasonCode:       "max_tool_calls_exceeded",
			Limit:            b.MaxToolCalls,
			Observed:         int(calls),
			Session:          sessionID,
			Tool:             toolName,
			ControlledCutoff: true,
		}), nil
	}

	// ── (C) Chain depth ──────────────────────────────────────────────────
	depth, err := s.rdb.Incr(ctx, "chain_depth:"+sessionID).Result()
	if err == nil {
		_ = s.rdb.Expire(ctx, "chain_depth:"+sessionID, ttl).Err()
	}
	if depth > int64(b.MaxChainDepth) {
		return denyJSON(typev3.StatusCode_TooManyRequests, denyBody{
			ReasonCode:       "max_chain_depth_exceeded",
			Limit:            b.MaxChainDepth,
			Observed:         int(depth),
			Session:          sessionID,
			Tool:             toolName,
			ControlledCutoff: true,
		}), nil
	}

	// ── (D) Repetition detection ─────────────────────────────────────────
	argsHash := hashArgs(rpc.Params.Arguments)
	callKey := toolName + "|" + argsHash
	recentKey := "recent_calls:" + sessionID
	// Count duplicates within the current window BEFORE we push the new
	// call. If we hit the threshold, deny.
	recent, _ := s.rdb.LRange(ctx, recentKey, 0, int64(b.RepetitionWindow-1)).Result()
	dups := 0
	for _, r := range recent {
		if r == callKey {
			dups++
		}
	}
	if dups >= b.RepetitionMaxDups {
		return denyJSON(typev3.StatusCode_TooManyRequests, denyBody{
			ReasonCode:       "repetition_detected",
			Limit:            b.RepetitionMaxDups,
			Observed:         dups + 1,
			Session:          sessionID,
			Tool:             toolName,
			Detail:           fmt.Sprintf("same call (tool=%s, args-hash=%s) repeated within last %d calls", toolName, argsHash[:8], b.RepetitionWindow),
			ControlledCutoff: true,
		}), nil
	}
	// Record this call as the most recent.
	_ = s.rdb.LPush(ctx, recentKey, callKey).Err()
	_ = s.rdb.LTrim(ctx, recentKey, 0, int64(b.RepetitionWindow-1)).Err()
	_ = s.rdb.Expire(ctx, recentKey, ttl).Err()

	return allow(), nil
}

// ─── deny body ──────────────────────────────────────────────────────────────

type denyBody struct {
	ReasonCode       string `json:"reason_code"`
	Limit            int    `json:"limit"`
	Observed         int    `json:"observed"`
	Session          string `json:"session"`
	Tool             string `json:"tool"`
	Detail           string `json:"detail,omitempty"`
	ControlledCutoff bool   `json:"controlled_cutoff"`
}

func denyJSON(httpCode typev3.StatusCode, body denyBody) *authpb.CheckResponse {
	raw, _ := json.Marshal(body)
	// DeniedHttpResponse.Headers wants []*envoy.config.core.v3.HeaderValueOption.
	// Pulling that package in just to set Content-Type would mean another
	// transitive import; the body parses fine as text/plain at the client
	// edge since the inspector reads it as a string and parses by shape.
	return &authpb.CheckResponse{
		Status: &rpcstatus.Status{Code: 7, Message: body.ReasonCode},
		HttpResponse: &authpb.CheckResponse_DeniedResponse{
			DeniedResponse: &authpb.DeniedHttpResponse{
				Status: &typev3.HttpStatus{Code: httpCode},
				Body:   string(raw),
			},
		},
	}
}

func allow() *authpb.CheckResponse {
	return &authpb.CheckResponse{
		Status: &rpcstatus.Status{Code: 0},
		HttpResponse: &authpb.CheckResponse_OkResponse{
			OkResponse: &authpb.OkHttpResponse{},
		},
	}
}

func lookupHeader(headers map[string]string, key string) string {
	if v, ok := headers[strings.ToLower(key)]; ok {
		return v
	}
	if v, ok := headers[key]; ok {
		return v
	}
	return ""
}

func hashArgs(args map[string]interface{}) string {
	if args == nil {
		args = map[string]interface{}{}
	}
	// Stable sort keys to get a canonical serialisation.
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	ordered := make([]interface{}, 0, 2*len(keys))
	for _, k := range keys {
		ordered = append(ordered, k, args[k])
	}
	raw, _ := json.Marshal(ordered)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// ─── main ───────────────────────────────────────────────────────────────────

func mustGet(env, def string) string {
	if v := os.Getenv(env); v != "" {
		return v
	}
	return def
}

func main() {
	budgetsPath := mustGet("BUDGETS_PATH", "/etc/budgets/budgets.yaml")
	listenAddr := mustGet("LISTEN_ADDR", ":9001")
	healthAddr := mustGet("HEALTH_ADDR", ":8080")
	redisAddr := mustGet("REDIS_ADDR", "redis.runaway-containment.svc.cluster.local:6379")

	store := &budgetStore{path: budgetsPath}
	store.reload()

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Printf("WARN: redis ping %s failed: %v — counters will fail open", redisAddr, err)
	}

	srv := grpc.NewServer()
	authpb.RegisterAuthorizationServer(srv, &authServer{store: store, rdb: rdb})

	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", listenAddr, err)
	}

	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
			fmt.Fprintln(w, "ok")
		})
		// /reset?session=<sid> — wipes the counters for that session. Used by
		// the inspector UI's "Reset session" button.
		mux.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
			sid := r.URL.Query().Get("session")
			if sid == "" {
				http.Error(w, "missing session", http.StatusBadRequest)
				return
			}
			keys := []string{
				"tool_calls:" + sid,
				"turns:" + sid,
				"chain_depth:" + sid,
				"recent_calls:" + sid,
				"last_turn:" + sid,
			}
			_ = rdb.Del(context.Background(), keys...).Err()
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, "{\"reset\":%q}\n", sid)
		})
		// /state?session=<sid> — peek at the current counters so the UI can
		// render the live counter panel.
		mux.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
			sid := r.URL.Query().Get("session")
			if sid == "" {
				http.Error(w, "missing session", http.StatusBadRequest)
				return
			}
			ctx := r.Context()
			calls, _ := rdb.Get(ctx, "tool_calls:"+sid).Int()
			turns, _ := rdb.Get(ctx, "turns:"+sid).Int()
			depth, _ := rdb.Get(ctx, "chain_depth:"+sid).Int()
			recent, _ := rdb.LRange(ctx, "recent_calls:"+sid, 0, -1).Result()
			b := store.get()
			out := map[string]interface{}{
				"session":     sid,
				"tool_calls":  calls,
				"turns":       turns,
				"chain_depth": depth,
				"recent":      recent,
				"limits": map[string]int{
					"max_tool_calls":     b.MaxToolCalls,
					"max_turns":          b.MaxTurns,
					"max_chain_depth":    b.MaxChainDepth,
					"repetition_window":  b.RepetitionWindow,
					"repetition_max_dup": b.RepetitionMaxDups,
				},
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(out)
		})
		log.Printf("health/admin server on %s", healthAddr)
		_ = http.ListenAndServe(healthAddr, mux)
	}()

	log.Printf("budget-extauth gRPC on %s — budgets=%s redis=%s",
		listenAddr, budgetsPath, redisAddr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

