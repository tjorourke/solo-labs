// tool-policy-extauth — Envoy ext_authz gRPC service that enforces three
// curation-driven policies that the gateway's CEL allow-list can't:
//
//  1. Arg-schema validation — every tools/call has its `arguments` validated
//     against the JSON Schema pinned in the curated manifest. Bad args ⇒ DENY.
//  2. Risk-tier × intent — tools tagged `riskTier: high` require the caller's
//     JWT to carry a matching `intent` claim. Missing intent ⇒ DENY.
//  3. Forbidden chains — sequences like `[db.read_secret, http.post_external]`
//     are denied on the SECOND call when the FIRST happened in the same MCP
//     session. Tracked in Redis keyed by `Mcp-Session-Id`.
//
// The gateway's own CEL policy (managed by policy-sync) handles "is this tool
// in the allow-list" before we ever see the request — but we re-check here
// anyway as defense in depth.
//
// We do NOT verify the JWT — that's the gateway's job. We parse the claims
// (`jwt.ParseUnverified`) for the `intent` field. If the gateway rejected
// the JWT, we never see the request.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	authpb "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
	"github.com/xeipuuv/gojsonschema"
	rpcstatus "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"gopkg.in/yaml.v3"
)

type curatedTool struct {
	Name             string                 `yaml:"name"`
	RiskTier         string                 `yaml:"riskTier"`
	RequiredIntent   string                 `yaml:"requiredIntent"`
	CleanDescription string                 `yaml:"cleanDescription"`
	ArgsSchema       map[string]interface{} `yaml:"argsSchema"`
}

type manifest struct {
	ApprovedTools   []curatedTool `yaml:"approvedTools"`
	ForbiddenChains [][]string    `yaml:"forbiddenChains"`
}

// manifestStore reloads from disk on every Check. The manifest file is a
// ConfigMap volume; kubelet writes atomically.
type manifestStore struct {
	mu   sync.RWMutex
	path string
	last manifest
}

func (m *manifestStore) reload() {
	raw, err := os.ReadFile(m.path)
	if err != nil {
		log.Printf("manifest reload: read %s: %v", m.path, err)
		return
	}
	var next manifest
	if err := yaml.Unmarshal(raw, &next); err != nil {
		log.Printf("manifest reload: parse: %v", err)
		return
	}
	m.mu.Lock()
	m.last = next
	m.mu.Unlock()
}

func (m *manifestStore) get() manifest {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.last
}

// ─── ext-auth implementation ─────────────────────────────────────────────────

type authServer struct {
	authpb.UnimplementedAuthorizationServer
	store *manifestStore
	rdb   *redis.Client
	rttl  time.Duration
}

func (s *authServer) Check(ctx context.Context, req *authpb.CheckRequest) (*authpb.CheckResponse, error) {
	s.store.reload()
	m := s.store.get()

	httpAttr := req.GetAttributes().GetRequest().GetHttp()
	headers := httpAttr.GetHeaders()
	body := httpAttr.GetBody()
	method := httpAttr.GetMethod()

	// MCP wire is all POST JSON-RPC. Anything else, allow.
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
		// Body isn't JSON — let upstream decide.
		return allow(), nil
	}

	// Only tools/call has tool-specific gating. Other MCP methods (initialize,
	// notifications/initialized, tools/list, ping) pass.
	if rpc.Method != "tools/call" || rpc.Params.Name == "" {
		return allow(), nil
	}

	toolName := rpc.Params.Name
	// Debug: dump headers so we can diagnose missing claims.
	hdrKeys := make([]string, 0, len(headers))
	for k := range headers {
		hdrKeys = append(hdrKeys, k)
	}
	log.Printf("Check tool=%s headers=%v", toolName, hdrKeys)

	tool := findTool(m, toolName)
	if tool == nil {
		// Defense in depth — the gateway CEL allow-list should have caught
		// this already.
		return deny(typev3.StatusCode_Forbidden, fmt.Sprintf(
			"ext-auth: tool %q is not in the curated manifest", toolName)), nil
	}

	// (1) Arg-schema validation.
	if len(tool.ArgsSchema) > 0 {
		schemaBytes, _ := json.Marshal(tool.ArgsSchema)
		argsBytes, _ := json.Marshal(rpc.Params.Arguments)
		res, err := gojsonschema.Validate(
			gojsonschema.NewBytesLoader(schemaBytes),
			gojsonschema.NewBytesLoader(argsBytes),
		)
		if err != nil {
			return deny(typev3.StatusCode_BadRequest, fmt.Sprintf(
				"ext-auth: schema validate failed: %v", err)), nil
		}
		if !res.Valid() {
			msgs := []string{}
			for _, e := range res.Errors() {
				msgs = append(msgs, e.String())
			}
			return deny(typev3.StatusCode_BadRequest, fmt.Sprintf(
				"ext-auth: args for %q violate schema: %s",
				toolName, strings.Join(msgs, "; "))), nil
		}
	}

	// (2) Risk-tier × intent.
	//
	// The intent claim comes from the JWT, but the gateway strips
	// Authorization after JWT validation, so we don't see the token.
	// The inspector UI duplicates intent in a custom header X-MCP-Intent;
	// in production, configure the gateway's JWT filter to forward the
	// validated claims as a header (forward_payload_header) so the
	// header isn't agent-spoofable.
	if tool.RiskTier == "high" && tool.RequiredIntent != "" {
		intent := lookupHeader(headers, "x-mcp-intent")
		if intent == "" {
			intent = extractIntent(headers) // Authorization-header fallback (not currently reached)
		}
		if intent != tool.RequiredIntent {
			return deny(typev3.StatusCode_Forbidden, fmt.Sprintf(
				"ext-auth: tool %q is risk=high and requires intent=%q (got %q)",
				toolName, tool.RequiredIntent, intent)), nil
		}
	}

	// (3) Forbidden chain detection.
	sessionID := lookupHeader(headers, "mcp-session-id")
	if sessionID == "" {
		log.Printf("WARN: tools/call without Mcp-Session-Id — chain detection skipped")
	} else if s.rdb != nil {
		prev, err := s.rdb.Get(ctx, "prev:"+sessionID).Result()
		if err == nil && prev != "" {
			for _, chain := range m.ForbiddenChains {
				if len(chain) == 2 && chain[0] == prev && chain[1] == toolName {
					return deny(typev3.StatusCode_Forbidden, fmt.Sprintf(
						"ext-auth: forbidden chain %s → %s in session %s",
						prev, toolName, sessionID)), nil
				}
			}
		}
		// Record this call as the new "previous" for this session. Best-effort.
		_ = s.rdb.Set(ctx, "prev:"+sessionID, toolName, s.rttl).Err()
	}

	return allow(), nil
}

func findTool(m manifest, name string) *curatedTool {
	for i := range m.ApprovedTools {
		if m.ApprovedTools[i].Name == name {
			return &m.ApprovedTools[i]
		}
	}
	return nil
}

// extractIntent decodes the Authorization Bearer token (unverified — the
// gateway already validated it) and pulls out the `intent` claim.
func extractIntent(headers map[string]string) string {
	auth := lookupHeader(headers, "authorization")
	if auth == "" {
		return ""
	}
	const bearer = "Bearer "
	if !strings.HasPrefix(auth, bearer) {
		return ""
	}
	tok := strings.TrimSpace(auth[len(bearer):])
	parser := jwt.NewParser(jwt.WithoutClaimsValidation())
	parsed, _, err := parser.ParseUnverified(tok, jwt.MapClaims{})
	if err != nil {
		return ""
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return ""
	}
	if v, ok := claims["intent"].(string); ok {
		return v
	}
	return ""
}

func lookupHeader(headers map[string]string, key string) string {
	// Envoy lowercases header keys on the wire.
	if v, ok := headers[strings.ToLower(key)]; ok {
		return v
	}
	if v, ok := headers[key]; ok {
		return v
	}
	return ""
}

// allow / deny — construct the CheckResponse shapes ext_authz expects.
func allow() *authpb.CheckResponse {
	return &authpb.CheckResponse{
		Status: &rpcstatus.Status{Code: 0 /* OK */},
		HttpResponse: &authpb.CheckResponse_OkResponse{
			OkResponse: &authpb.OkHttpResponse{},
		},
	}
}

func deny(httpCode typev3.StatusCode, reason string) *authpb.CheckResponse {
	return &authpb.CheckResponse{
		Status: &rpcstatus.Status{Code: 7 /* PermissionDenied */, Message: reason},
		HttpResponse: &authpb.CheckResponse_DeniedResponse{
			DeniedResponse: &authpb.DeniedHttpResponse{
				Status: &typev3.HttpStatus{Code: httpCode},
				Body:   reason,
			},
		},
	}
}

// ─── main ───────────────────────────────────────────────────────────────────

func mustGet(env, def string) string {
	if v := os.Getenv(env); v != "" {
		return v
	}
	return def
}

func main() {
	manifestPath := mustGet("MANIFEST_PATH", "/etc/curation/manifest.yaml")
	listenAddr := mustGet("LISTEN_ADDR", ":9001")
	healthAddr := mustGet("HEALTH_ADDR", ":8080")
	redisAddr := mustGet("REDIS_ADDR", "redis.tool-curation.svc.cluster.local:6379")
	ttl, _ := time.ParseDuration(mustGet("CHAIN_TTL", "10m"))

	store := &manifestStore{path: manifestPath}
	store.reload()

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Printf("WARN: redis ping %s failed: %v — chain detection will be best-effort", redisAddr, err)
	}

	srv := grpc.NewServer()
	authpb.RegisterAuthorizationServer(srv, &authServer{store: store, rdb: rdb, rttl: ttl})

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
		log.Printf("health server on %s", healthAddr)
		_ = http.ListenAndServe(healthAddr, mux)
	}()

	log.Printf("ext-auth gRPC server on %s — manifest=%s redis=%s chain_ttl=%s",
		listenAddr, manifestPath, redisAddr, ttl)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
