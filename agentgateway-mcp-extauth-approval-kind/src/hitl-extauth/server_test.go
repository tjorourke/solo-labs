package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"google.golang.org/grpc/codes"
	"gopkg.in/yaml.v3"
)

func checkTool(t *testing.T, e *extAuthServer, path, tool string) *auth.CheckResponse {
	t.Helper()
	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{Request: &auth.AttributeContext_Request{Http: &auth.AttributeContext_HttpRequest{
		Path: path, Body: `{"method":"tools/call","params":{"name":"` + tool + `","server":"users-mcp"}}`,
		Headers: map[string]string{"x-mcp-server": "users-mcp"},
	}}}}
	got, err := e.Check(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestCheckUsesRouteServer(t *testing.T) {
	for _, tc := range []struct {
		path, tool string
		want       codes.Code
		parked     bool
	}{
		{"/mcp", "get_users", codes.OK, false},
		{"/mcp?session=1", "get_users", codes.OK, false},
		// Not in the approve list: ext-auth passes it and native MCP
		// authorization on the backend hides and denies it.
		{"/mcp", "wipe_users", codes.OK, false},
		{"/mcp", "", codes.OK, false},
		// The server comes from the route path, never from body or headers.
		{"/other", "delete_user", codes.OK, false},
		{"/mcp/other", "delete_user", codes.OK, false},
		{"/mcp", "users-mcp_delete_user", codes.OK, false},
		// Parked, then denied when the short test TTL expires.
		{"/mcp", "delete_user", codes.PermissionDenied, true},
		{"/mcp?session=1", "delete_user", codes.PermissionDenied, true},
	} {
		t.Run(tc.path+"/"+tc.tool, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "policy.yaml")
			if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [delete_.*]\n"), 0600); err != nil {
				t.Fatal(err)
			}
			e := &extAuthServer{q: newQueue(20 * time.Millisecond), store: newPolicyStore(path)}
			got := checkTool(t, e, tc.path, tc.tool)
			if got.Status.Code != int32(tc.want) {
				t.Fatalf("got %v, want %v", got.Status, tc.want)
			}
			timedOut := strings.Contains(got.GetDeniedResponse().GetBody(), "timed out")
			if timedOut != tc.parked {
				t.Fatalf("parked=%v, want %v (%s)", timedOut, tc.parked, got.GetDeniedResponse().GetBody())
			}
		})
	}
}

func TestCheckFailsClosedWithoutPolicy(t *testing.T) {
	e := &extAuthServer{q: newQueue(time.Second), store: newPolicyStore(filepath.Join(t.TempDir(), "missing.yaml"))}
	got := checkTool(t, e, "/mcp", "delete_user")
	if got.Status.Code != int32(codes.PermissionDenied) || !strings.Contains(got.GetDeniedResponse().GetBody(), "fail closed") {
		t.Fatalf("got %v %s, want fail-closed deny", got.Status, got.GetDeniedResponse().GetBody())
	}
	if got := checkTool(t, e, "/mcp", ""); got.Status.Code != int32(codes.OK) {
		t.Fatalf("handshake got %v, want OK", got.Status)
	}
}

type manifest struct {
	Kind     string
	Metadata struct{ Name string }
	Spec     struct {
		TargetRefs []struct{ Group, Kind, Name string } `yaml:"targetRefs"`
		Rules      []struct {
			Matches  []struct{ Path struct{ Type, Value string } } `yaml:"matches"`
			Backends []struct {
				Group, Kind, Name string
				Port              int
			} `yaml:"backendRefs"`
		} `yaml:"rules"`
		MCP struct {
			Targets []struct {
				Name   string
				Static struct {
					Host string
					Port int
					Path string
				}
			}
		} `yaml:"mcp"`
		Backend struct {
			MCP struct {
				Authorization struct {
					Action string
					Policy struct {
						MatchExpressions []string `yaml:"matchExpressions"`
					}
				}
			} `yaml:"mcp"`
		}
	}
}

func readManifest(t *testing.T, path string) manifest {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// Prevent the explicit lab binding drifting when an edition's route, MCP
// backend or native tool policy changes.
func TestRouteManifestsMatchServerBinding(t *testing.T) {
	server := serverForPath("/mcp")
	for _, ed := range []struct{ dir, group, backendKind string }{
		{"../../yaml/agentgateway", "agentgateway.dev", "AgentgatewayBackend"},
		{"../../yaml-oss/agentgateway", "agentgateway.dev", "AgentgatewayBackend"},
		{"../../yaml-enterprise", "enterpriseagentgateway.solo.io", "EnterpriseAgentgatewayBackend"},
	} {
		t.Run(ed.dir, func(t *testing.T) {
			route := readManifest(t, ed.dir+"/httproute.yaml")
			if len(route.Spec.Rules) != 1 {
				t.Fatal("server binding needs exactly one route rule")
			}
			r := route.Spec.Rules[0]
			if len(r.Matches) != 1 || r.Matches[0].Path.Type != "Exact" || r.Matches[0].Path.Value != "/mcp" {
				t.Fatal("route must match only /mcp")
			}
			if len(r.Backends) != 1 || r.Backends[0].Group != ed.group || r.Backends[0].Kind != ed.backendKind || r.Backends[0].Name != server {
				t.Fatalf("route must send /mcp only to the %s MCP backend: %+v", server, r.Backends)
			}

			backend := readManifest(t, ed.dir+"/mcp-backend.yaml")
			if backend.Kind != ed.backendKind || backend.Metadata.Name != server {
				t.Fatalf("backend %s/%s", backend.Kind, backend.Metadata.Name)
			}
			targets := backend.Spec.MCP.Targets
			if len(targets) != 1 || targets[0].Name != server || targets[0].Static.Port != 8080 || targets[0].Static.Path != "/mcp" ||
				!strings.HasPrefix(targets[0].Static.Host, server+".") {
				t.Fatalf("backend must have one %s target: %+v", server, targets)
			}

			authz := readManifest(t, ed.dir+"/mcp-authz.yaml")
			if len(authz.Spec.TargetRefs) != 1 || authz.Spec.TargetRefs[0].Group != ed.group ||
				authz.Spec.TargetRefs[0].Kind != ed.backendKind || authz.Spec.TargetRefs[0].Name != server {
				t.Fatalf("native policy must target the MCP backend: %+v", authz.Spec.TargetRefs)
			}
			a := authz.Spec.Backend.MCP.Authorization
			cel := strings.Join(a.Policy.MatchExpressions, "\n")
			if a.Action != "Allow" || !strings.Contains(cel, `"delete_user"`) || !strings.Contains(cel, `"get_users"`) ||
				strings.Contains(cel, "wipe_users") || !strings.Contains(cel, `mcp.tool.target == "`+server+`"`) {
				t.Fatalf("native allow-list must let delete_user reach review and leave wipe_users out: %s", cel)
			}
		})
	}
}

func TestServerBindingRejectsAliases(t *testing.T) {
	for _, path := range []string{"", "/", "/mcp/", "/%6dcp", "/mcp%2fother", "/other/../mcp", "bad path"} {
		if got := serverForPath(path); got != "" {
			t.Errorf("%q resolved to %q", path, got)
		}
	}
}

func TestPolicyHTTPResponse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [delete_.*]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	handler := newAdminHandler(newQueue(time.Second), newPolicyStore(path))
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest("GET", "/policy", nil))
	if rr.Code != 200 {
		t.Fatalf("status=%d", rr.Code)
	}
	var body struct {
		Servers map[string]map[string][]string `json:"servers"`
		Path    string                         `json:"path"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{"approve": {"delete_.*"}}
	got := body.Servers["users-mcp"]
	if body.Path != path || len(body.Servers) != 1 || len(got) != 1 || len(got["approve"]) != 1 || got["approve"][0] != want["approve"][0] {
		t.Fatalf("unexpected response: %s", rr.Body.String())
	}
}
