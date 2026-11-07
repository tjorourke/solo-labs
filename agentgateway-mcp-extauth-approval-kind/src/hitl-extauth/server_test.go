package main

import (
	"context"
	"encoding/json"
	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"google.golang.org/grpc/codes"
	"gopkg.in/yaml.v3"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCheckUsesRouteServer(t *testing.T) {
	for _, tc := range []struct {
		path, tool string
		want       codes.Code
	}{
		{"/mcp", "get_users", codes.OK},
		{"/mcp?session=1", "get_users", codes.OK},
		{"/other", "get_users", codes.PermissionDenied},
		{"/other", "delete_user", codes.PermissionDenied},
		{"/other", "", codes.OK},
		{"/mcp/other", "get_users", codes.PermissionDenied},
		{"/mcp", "users-mcp__get_users", codes.PermissionDenied},
		{"/mcp", "wipe_users", codes.PermissionDenied},
	} {
		t.Run(tc.path+"/"+tc.tool, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "policy.yaml")
			if err := os.WriteFile(path, []byte("users-mcp:\n  allow: [get_.*]\n  approve: [delete_.*]\n  deny: []\n"), 0600); err != nil {
				t.Fatal(err)
			}
			e := &extAuthServer{q: newQueue(time.Second), store: newPolicyStore(path)}
			req := &auth.CheckRequest{Attributes: &auth.AttributeContext{Request: &auth.AttributeContext_Request{Http: &auth.AttributeContext_HttpRequest{
				Path: tc.path, Body: `{"method":"tools/call","params":{"name":"` + tc.tool + `","server":"users-mcp"}}`,
				Headers: map[string]string{"x-mcp-server": "users-mcp"},
			}}}}
			got, err := e.Check(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if got.Status.Code != int32(tc.want) {
				t.Fatalf("got %v, want %v", got.Status, tc.want)
			}
		})
	}
}

// Prevent the explicit lab binding drifting when an edition's route changes.
func TestRouteManifestsMatchServerBinding(t *testing.T) {
	for _, path := range []string{
		"../../yaml/agentgateway/httproute.yaml",
		"../../yaml-oss/agentgateway/httproute.yaml",
		"../../yaml-enterprise/httproute.yaml",
	} {
		t.Run(path, func(t *testing.T) {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var route struct {
				Spec struct {
					Rules []struct {
						Matches  []struct{ Path struct{ Type, Value string } } `yaml:"matches"`
						Backends []struct {
							Name string
							Port int
						} `yaml:"backendRefs"`
					} `yaml:"rules"`
				} `yaml:"spec"`
			}
			if err := yaml.Unmarshal(data, &route); err != nil {
				t.Fatal(err)
			}
			if len(route.Spec.Rules) != 1 {
				t.Fatal("server binding needs exactly one route rule")
			}
			r := route.Spec.Rules[0]
			if len(r.Matches) != 1 || r.Matches[0].Path.Type != "Exact" || r.Matches[0].Path.Value != "/mcp" {
				t.Fatal("route must match only /mcp")
			}
			if len(r.Backends) != 1 || r.Backends[0].Name != serverForPath("/mcp") || r.Backends[0].Port != 8080 {
				t.Fatal("route and Check server binding disagree")
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
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow: [get_.*]\n  approve: [delete_.*]\n  deny: []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	handler := newAdminHandler(newQueue(time.Second), newPolicyStore(path))
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest("GET", "/policy", nil))
	if rr.Code != 200 {
		t.Fatalf("status=%d", rr.Code)
	}
	var body struct {
		Servers map[string]ServerPolicy `json:"servers"`
		Path    string                  `json:"path"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Path != path || len(body.Servers) != 1 || len(body.Servers["users-mcp"].Approve) != 1 {
		t.Fatalf("unexpected response: %s", rr.Body.String())
	}
}
