// hitl-extauth: Envoy ext-auth gRPC service that parks a Check() call on a Go
// channel until a decision arrives via the admin HTTP API.
//
// Adapted from agentic-hitl-kind's hitl-extauth: that lab gates by HTTPRoute
// path (two endpoints, /public and /privileged) and parks everything that
// reaches the privileged one. This variant gates a single endpoint by reading
// the tool name out of the JSON-RPC body and looking it up in a mounted
// ConfigMap (allow / approve / deny). That is what lets one MCP server expose
// both get_users (allowed) and delete_user (needs approval) on one route,
// one policy, without baking the names into the image.
//
// Two listeners:
//
//	:9001  gRPC  envoy.service.auth.v3.Authorization, consumed by agentgateway
//	:8081  HTTP  admin API, consumed by curl, or a queue UI
//
//	  GET  /pending           → list parked requests
//	  POST /decide/{id}       → {"approved": bool, "reason": string}
//	  GET  /policy            → the lists currently loaded from the ConfigMap
//	  GET  /metrics           → Prometheus metrics, including approval_needed_total
//	  GET  /healthz
//
// The gating decision (which tools pass, which park, which are denied) lives
// entirely in this service's Check(), driven by the ConfigMap. agentgateway
// does not know or care which tool was called; it just does what Check()
// tells it.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	auth_v3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	envoy_type_v3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
)

// ─── Types ────────────────────────────────────────────────────────────────────

type Decision struct {
	Approved bool   `json:"approved"`
	Reason   string `json:"reason,omitempty"`
}

type Pending struct {
	ID         string            `json:"id"`
	ReceivedAt time.Time         `json:"receivedAt"`
	Method     string            `json:"method"`
	Path       string            `json:"path"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body,omitempty"`

	RPCMethod string         `json:"rpcMethod,omitempty"` // "initialize" / "tools/list" / "tools/call" / ...
	ToolName  string         `json:"toolName,omitempty"`  // only set when RPCMethod == "tools/call"
	ToolArgs  map[string]any `json:"toolArgs,omitempty"`  // only set when RPCMethod == "tools/call"

	decision chan Decision `json:"-"`
}

type Queue struct {
	mu      sync.Mutex
	pending map[string]*Pending
	counter atomic.Uint64
	parkTTL time.Duration
}

func newQueue(ttl time.Duration) *Queue {
	return &Queue{
		pending: map[string]*Pending{},
		parkTTL: ttl,
	}
}

func (q *Queue) park(p *Pending) Decision {
	q.mu.Lock()
	q.pending[p.ID] = p
	n := len(q.pending)
	q.mu.Unlock()
	hitlPending.Set(float64(n))
	defer func() {
		q.mu.Lock()
		delete(q.pending, p.ID)
		n := len(q.pending)
		q.mu.Unlock()
		hitlPending.Set(float64(n))
	}()
	select {
	case d := <-p.decision:
		return d
	case <-time.After(q.parkTTL):
		return Decision{Approved: false, Reason: fmt.Sprintf("timed out after %s", q.parkTTL)}
	}
}

func (q *Queue) decide(id string, d Decision) bool {
	q.mu.Lock()
	p, ok := q.pending[id]
	q.mu.Unlock()
	if !ok {
		return false
	}
	select {
	case p.decision <- d:
		return true
	case <-time.After(time.Second):
		return false
	}
}

func (q *Queue) snapshot() []*Pending {
	q.mu.Lock()
	defer q.mu.Unlock()
	out := make([]*Pending, 0, len(q.pending))
	for _, p := range q.pending {
		out = append(out, p)
	}
	return out
}

// ─── JSON-RPC body parsing ──────────────────────────────────────────────────

// parseMCP returns (rpcMethod, toolName, toolArgs). rpcMethod is set for any
// well-formed JSON-RPC body so non-tools/call frames (initialize, tools/list,
// ping) can be told apart from real tool invocations. toolName and toolArgs
// are populated only for tools/call.
func parseMCP(body string) (string, string, map[string]any) {
	if body == "" {
		return "", "", nil
	}
	var rpc struct {
		Method string `json:"method"`
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(body), &rpc); err != nil {
		return "", "", nil
	}
	if rpc.Method != "tools/call" {
		return rpc.Method, "", nil
	}
	return rpc.Method, rpc.Params.Name, rpc.Params.Arguments
}

func okResponse() *auth_v3.CheckResponse {
	return &auth_v3.CheckResponse{
		Status: &status.Status{Code: int32(codes.OK)},
		HttpResponse: &auth_v3.CheckResponse_OkResponse{
			OkResponse: &auth_v3.OkHttpResponse{},
		},
	}
}

func deniedResponse(id, reason string) *auth_v3.CheckResponse {
	denyBody, _ := json.Marshal(map[string]any{
		"approved": false,
		"reason":   reason,
		"id":       id,
	})
	return &auth_v3.CheckResponse{
		Status: &status.Status{Code: int32(codes.PermissionDenied)},
		HttpResponse: &auth_v3.CheckResponse_DeniedResponse{
			DeniedResponse: &auth_v3.DeniedHttpResponse{
				Status: &envoy_type_v3.HttpStatus{Code: envoy_type_v3.StatusCode_Forbidden},
				Body:   string(denyBody),
			},
		},
	}
}

// ─── gRPC ext-auth ────────────────────────────────────────────────────────────

type extAuthServer struct {
	auth_v3.UnimplementedAuthorizationServer
	q     *Queue
	store *PolicyStore
}

func (e *extAuthServer) Check(ctx context.Context, req *auth_v3.CheckRequest) (*auth_v3.CheckResponse, error) {
	httpReq := req.GetAttributes().GetRequest().GetHttp()
	id := fmt.Sprintf("p-%d", e.q.counter.Add(1))

	rpcMethod, toolName, toolArgs := parseMCP(httpReq.GetBody())
	verdict, reason := e.store.snapshot().decide(toolName)
	if toolName != "" {
		recordVerdict(verdict, toolName)
	}

	if verdict == VerdictAllow {
		log.Printf("[passthrough] id=%s method=%s path=%s rpc=%q tool=%q reason=%q",
			id, httpReq.GetMethod(), httpReq.GetPath(), rpcMethod, toolName, reason)
		return okResponse(), nil
	}

	if verdict == VerdictDeny {
		log.Printf("[denied] id=%s method=%s path=%s rpc=%q tool=%q reason=%q",
			id, httpReq.GetMethod(), httpReq.GetPath(), rpcMethod, toolName, reason)
		return deniedResponse(id, reason), nil
	}

	p := &Pending{
		ID:         id,
		ReceivedAt: time.Now().UTC(),
		Method:     httpReq.GetMethod(),
		Path:       httpReq.GetPath(),
		Headers:    httpReq.GetHeaders(),
		Body:       httpReq.GetBody(),
		RPCMethod:  rpcMethod,
		ToolName:   toolName,
		ToolArgs:   toolArgs,
		decision:   make(chan Decision, 1),
	}

	log.Printf("[parked] id=%s method=%s path=%s rpc=%s tool=%s args=%v reason=%q",
		id, p.Method, p.Path, rpcMethod, toolName, toolArgs, reason)

	d := e.q.park(p)

	if d.Approved {
		recordDecision("approved")
		log.Printf("[approved] id=%s reason=%q", id, d.Reason)
		return okResponse(), nil
	}
	if strings.HasPrefix(d.Reason, "timed out") {
		recordDecision("timeout")
	} else {
		recordDecision("rejected")
	}
	log.Printf("[denied] id=%s reason=%q", id, d.Reason)
	return deniedResponse(id, d.Reason), nil
}

// ─── HTTP admin API ───────────────────────────────────────────────────────────

func newAdminHandler(q *Queue, store *PolicyStore) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /pending", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"pending": q.snapshot(),
		})
	})

	mux.HandleFunc("POST /decide/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var d Decision
		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, fmt.Sprintf("bad body: %v", err), http.StatusBadRequest)
			return
		}
		if !q.decide(id, d) {
			http.Error(w, "no such pending request", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("GET /policy", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(store.status())
	})

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("GET /metrics", promhttp.Handler())

	return mux
}

// ─── entrypoint ───────────────────────────────────────────────────────────────

func main() {
	ttlStr := getenv("PARK_TIMEOUT_SEC", "300")
	ttl, err := strconv.Atoi(ttlStr)
	if err != nil || ttl < 1 {
		log.Fatalf("invalid PARK_TIMEOUT_SEC=%q", ttlStr)
	}

	q := newQueue(time.Duration(ttl) * time.Second)
	store := newPolicyStore(getenv("POLICY_PATH", "/etc/hitl/policy.yaml"))

	grpcAddr := ":" + getenv("GRPC_PORT", "9001")
	httpAddr := ":" + getenv("HTTP_PORT", "8081")

	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", grpcAddr, err)
	}
	s := grpc.NewServer()
	auth_v3.RegisterAuthorizationServer(s, &extAuthServer{q: q, store: store})

	log.Printf("ext-auth gRPC=%s admin HTTP=%s parkTTL=%s policy=%s",
		grpcAddr, httpAddr, q.parkTTL, store.path)

	go func() {
		if err := s.Serve(lis); err != nil {
			log.Fatalf("gRPC serve: %v", err)
		}
	}()

	if err := http.ListenAndServe(httpAddr, newAdminHandler(q, store)); err != nil {
		log.Fatalf("http serve: %v", err)
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
