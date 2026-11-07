package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testSTS      = "sts.example:7777"
	testKeycloak = "http://idp.example/realms/demo"
)

func fixtureToken(payload string) string {
	return "e30." + base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".fixture"
}

// parkOne runs one delete_user call through Check() and returns the raw
// GET /pending body plus the single parked entry.
func parkOne(t *testing.T, token string) (string, map[string]any) {
	t.Helper()
	q := newQueue(time.Second)
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [delete_user]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	store := newPolicyStore(path)
	server := &extAuthServer{q: q, store: store}
	handler := newAdminHandler(q, store)
	body := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_user","arguments":{"id":"u-2","nested":{"keep":[1,2]}}}}`
	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{Request: &auth.AttributeContext_Request{Http: &auth.AttributeContext_HttpRequest{Method: "POST", Path: "/mcp", Body: body, Headers: map[string]string{"Authorization": "Bearer " + token, "x-user": "mallory", "x-agent": "rogue", "cookie": "private"}}}}}
	done := make(chan struct{})
	go func() { defer close(done); _, _ = server.Check(context.Background(), req) }()
	t.Cleanup(func() {
		for _, p := range q.snapshot() {
			q.decide(p.ID, Decision{Approved: true})
		}
		<-done
	})
	deadline := time.Now().Add(time.Second)
	for len(q.snapshot()) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest("GET", "/pending", nil))
	var got struct {
		Pending []map[string]any `json:"pending"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Pending) != 1 {
		t.Fatalf("pending: %s", rr.Body.String())
	}
	raw := rr.Body.String()
	for _, secret := range []string{token, "Bearer ", "private", "mallory", "rogue"} {
		if strings.Contains(raw, secret) {
			t.Errorf("pending leaked a credential or spoofed header")
		}
	}
	p := got.Pending[0]
	if p["serverName"] != "users-mcp" {
		t.Errorf("server binding lost: %v", p)
	}
	if p["toolName"] != "delete_user" || p["toolArgs"].(map[string]any)["id"] != "u-2" {
		t.Errorf("tool args lost: %v", p)
	}
	return raw, p
}

func TestPendingDelegatedIdentity(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", testSTS)
	t.Setenv("USER_ISSUER", testKeycloak)
	_, p := parkOne(t, fixtureToken(`{"iss":"sts.example:7777","sub":"uuid-not-display-name","preferred_username":"bob","act":{"sub":"system:serviceaccount:demo:dba-agent"}}`))
	if p["user"] != "bob" || p["agent"] != "dba-agent" {
		t.Errorf("identity = %v / %v", p["user"], p["agent"])
	}
}

func TestPendingDirectUserIdentity(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", testSTS)
	t.Setenv("USER_ISSUER", testKeycloak)
	raw, p := parkOne(t, fixtureToken(`{"iss":"http://idp.example/realms/demo","sub":"uuid","preferred_username":"bob","may_act":{"sub":["system:serviceaccount:demo:dba-agent"]}}`))
	if p["user"] != "bob" {
		t.Errorf("user = %v", p["user"])
	}
	if _, ok := p["agent"]; ok || strings.Contains(raw, `"agent"`) {
		t.Errorf("direct user call recorded an agent: %s", raw)
	}
}

func TestDelegatedIdentityIgnoresUntrustedDisplayHeaders(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", testSTS)
	t.Setenv("USER_ISSUER", testKeycloak)
	user, agent := delegatedIdentity(map[string]string{"x-user": "bob", "x-agent": "dba-agent"})
	if user != "" || agent != "" {
		t.Fatal("trusted caller supplied display headers")
	}
}

func TestDelegatedIdentityRejectsWrongIssuerAndShape(t *testing.T) {
	for _, payload := range []string{
		`{}`,
		// Unknown issuer, with or without an actor.
		`{"iss":"wrong","preferred_username":"bob","act":{"sub":"system:serviceaccount:demo:dba-agent"}}`,
		`{"iss":"wrong","preferred_username":"bob"}`,
		// STS issuer must carry a ServiceAccount actor.
		`{"iss":"sts.example:7777","preferred_username":"bob"}`,
		`{"iss":"sts.example:7777","preferred_username":"bob","act":{"sub":"not-a-service-account"}}`,
		`{"iss":"sts.example:7777","preferred_username":"bob","act":"bad"}`,
		// A user-issuer token that claims an actor is not a direct sign-in.
		`{"iss":"http://idp.example/realms/demo","preferred_username":"bob","act":{"sub":"system:serviceaccount:demo:dba-agent"}}`,
		// No display name.
		`{"iss":"http://idp.example/realms/demo"}`,
	} {
		t.Setenv("DELEGATED_ISSUER", testSTS)
		t.Setenv("USER_ISSUER", testKeycloak)
		user, agent := delegatedIdentity(map[string]string{"authorization": "Bearer " + fixtureToken(payload)})
		if user != "" || agent != "" {
			t.Fatalf("claims %s produced identity %q/%q", payload, user, agent)
		}
	}
}

func TestDelegatedIdentityOSSAndMalformed(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", "")
	t.Setenv("USER_ISSUER", "")
	user, agent := delegatedIdentity(map[string]string{"authorization": "Bearer " + fixtureToken(`{"iss":"http://idp.example/realms/demo","preferred_username":"bob"}`)})
	if user != "" || agent != "" {
		t.Fatal("OSS path produced identity")
	}
	for _, auth := range []string{"", "Basic abc", "Bearer invalid", "Bearer a.!.b"} {
		t.Setenv("DELEGATED_ISSUER", testSTS)
		t.Setenv("USER_ISSUER", testKeycloak)
		user, agent := delegatedIdentity(map[string]string{"Authorization": auth})
		if user != "" || agent != "" {
			t.Fatal("malformed token produced identity")
		}
	}
}
