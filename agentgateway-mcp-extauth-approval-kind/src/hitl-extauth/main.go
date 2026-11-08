// hitl-extauth: Envoy ext-auth gRPC service that parks a Check() call on a Go
// channel until a decision arrives via the admin HTTP API.
//
// The HTTPRoute binds /mcp to the users-mcp MCP backend. Check() selects that
// server's block in the mounted ConfigMap and matches the JSON-RPC tool name
// against its approve list. A match is parked for a reviewer. Anything else
// passes, because agentgateway's native MCP authorization on the backend
// already decides which tools are visible and callable. Approve rules can
// change without an image rebuild. Adding another backend requires a separate
// route and serverForPath binding.
// Part 1 (agentic-hitl-kind) instead gates the entire /privileged route.
//
// Two listeners:
//
//	:9001  gRPC  envoy.service.auth.v3.Authorization, consumed by agentgateway
//	:8081  HTTP  admin API, consumed by curl, or a queue UI
//
//	  GET  /pending           → list parked requests
//	  POST /decide/{id}       → {"approved": bool, "reason": string}
//	  GET  /policy            → approve rules per server, loaded from the ConfigMap
//	  GET  /metrics           → Prometheus metrics, including approval_needed_total
//	  GET  /healthz
//
// Split of work: agentgateway's AgentgatewayPolicy backend.mcp.authorization
// allows or hides tools; this service only decides which allowed calls wait
// for a human. The one deny it raises itself is fail-closed, when no approve
// rules have loaded.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
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
	ID         string    `json:"id"`
	ReceivedAt time.Time `json:"receivedAt"`
	Method     string    `json:"method"`
	Path       string    `json:"path"`
	User       string    `json:"user,omitempty"`
	Agent      string    `json:"agent,omitempty"`

	RPCMethod  string         `json:"rpcMethod,omitempty"`  // "initialize" / "tools/list" / "tools/call" / ...
	ServerName string         `json:"serverName,omitempty"` // bound to the HTTPRoute, not supplied by the caller
	ToolName   string         `json:"toolName,omitempty"`   // only set when RPCMethod == "tools/call"
	ToolArgs   map[string]any `json:"toolArgs,omitempty"`   // only set when RPCMethod == "tools/call"

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

// serverForPath binds the ext-auth request path to the backend in httproute.yaml.
// All three edition manifests send /mcp only to the users-mcp MCP backend, whose
// single target is also named users-mcp. ext-auth runs as a route policy, so it
// sees the client's path, not the target path. This is an explicit lab route
// binding, not MCP server discovery.
// A new backend needs its own route and a corresponding binding here. Never
// infer the server from client headers, JSON params or a tool-name prefix.
func serverForPath(path string) string {
	uri, err := url.ParseRequestURI(path)
	if err == nil && uri.EscapedPath() == "/mcp" {
		return "users-mcp"
	}
	return ""
}

func (e *extAuthServer) Check(ctx context.Context, req *auth_v3.CheckRequest) (*auth_v3.CheckResponse, error) {
	httpReq := req.GetAttributes().GetRequest().GetHttp()
	id := fmt.Sprintf("p-%d", e.q.counter.Add(1))

	rpcMethod, toolName, toolArgs := parseMCP(httpReq.GetBody())
	serverName := serverForPath(httpReq.GetPath())
	verdict, reason := e.store.snapshot().decide(serverName, toolName)
	if toolName != "" {
		recordVerdict(verdict, serverName, toolName)
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

	user, agent := delegatedIdentity(httpReq.GetHeaders())
	p := &Pending{
		ID:         id,
		ReceivedAt: time.Now().UTC(),
		Method:     httpReq.GetMethod(),
		Path:       httpReq.GetPath(),
		User:       user,
		Agent:      agent,
		RPCMethod:  rpcMethod,
		ServerName: serverName,
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

// delegatedIdentity only extracts display claims after the gateway has validated
// the signature, issuer and audience. It is not a JWT verifier. Two issuers are
// trusted, each set by the Enterprise overlay:
//
//	DELEGATED_ISSUER  Solo STS. A minted token must carry act.sub as a
//	                  Kubernetes ServiceAccount: user and agent are recorded.
//	USER_ISSUER       The identity provider (Keycloak in this lab). A user's own
//	                  token has no act claim: only the user is recorded.
//
// Any other issuer, or a token whose shape does not match its issuer, records
// nothing. The OSS path sets neither variable. Never expose this gRPC service
// outside the trusted gateway network.
func delegatedIdentity(headers map[string]string) (string, string) {
	stsIssuer := os.Getenv("DELEGATED_ISSUER")
	userIssuer := os.Getenv("USER_ISSUER")
	if stsIssuer == "" && userIssuer == "" {
		return "", ""
	}
	var bearer string
	for k, v := range headers {
		if strings.EqualFold(k, "authorization") {
			bearer = v
			break
		}
	}
	fields := strings.Fields(bearer)
	if len(fields) != 2 || !strings.EqualFold(fields[0], "Bearer") {
		return "", ""
	}
	parts := strings.Split(fields[1], ".")
	if len(parts) != 3 {
		return "", ""
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", ""
	}
	var c struct {
		Issuer string          `json:"iss"`
		User   string          `json:"preferred_username"`
		Actor  json.RawMessage `json:"act"`
	}
	if json.Unmarshal(raw, &c) != nil || c.Issuer == "" || c.User == "" {
		return "", ""
	}
	switch {
	case stsIssuer != "" && c.Issuer == stsIssuer:
		var act struct {
			Subject string `json:"sub"`
		}
		if len(c.Actor) == 0 || json.Unmarshal(c.Actor, &act) != nil {
			return "", ""
		}
		sa := strings.Split(act.Subject, ":")
		if len(sa) != 4 || sa[0] != "system" || sa[1] != "serviceaccount" || sa[2] == "" || sa[3] == "" {
			return "", ""
		}
		return c.User, sa[3]
	case userIssuer != "" && c.Issuer == userIssuer:
		// A user token that claims an actor did not come from a direct sign-in.
		if len(c.Actor) != 0 && string(c.Actor) != "null" {
			return "", ""
		}
		return c.User, ""
	}
	return "", ""
}
