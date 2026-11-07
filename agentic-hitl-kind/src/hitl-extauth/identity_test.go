package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
)

func TestPendingDelegatedIdentity(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", "sts.example:7777")
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"iss":"sts.example:7777","sub":"uuid-not-display-name","preferred_username":"bob","act":{"sub":"system:serviceaccount:demo:dba-agent"}}`))
	token := "e30." + payload + ".fixture"
	q := newQueue(time.Second)
	server := &extAuthServer{q: q}
	handler := newAdminHandler(q)
	body := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_user","arguments":{"id":"u-2","nested":{"keep":[1,2]}}}}`
	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{Request: &auth.AttributeContext_Request{Http: &auth.AttributeContext_HttpRequest{Method: "POST", Path: "/mcp", Body: body, Headers: map[string]string{"Authorization": "Bearer " + token, "x-user": "mallory", "cookie": "private"}}}}}
	done := make(chan struct{})
	go func() { defer close(done); _, _ = server.Check(context.Background(), req) }()
	defer func() {
		for _, p := range q.snapshot() {
			q.decide(p.ID, Decision{Approved: true})
		}
		<-done
	}()
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
	p := got.Pending[0]
	if p["user"] != "bob" || p["agent"] != "dba-agent" {
		t.Errorf("identity = %v / %v", p["user"], p["agent"])
	}
	if p["toolName"] != "delete_user" || p["toolArgs"].(map[string]any)["id"] != "u-2" {
		t.Errorf("tool args lost: %v", p)
	}
	for _, secret := range []string{token, "Bearer ", "private"} {
		if strings.Contains(rr.Body.String(), secret) {
			t.Errorf("pending leaked credential")
		}
	}
}

func TestDelegatedIdentityIgnoresUntrustedDisplayHeaders(t *testing.T) {
	t.Setenv("DELEGATED_ISSUER", "sts.example:7777")
	user, agent := delegatedIdentity(map[string]string{"x-user": "bob", "x-agent": "dba-agent"})
	if user != "" || agent != "" {
		t.Fatal("trusted caller supplied display headers")
	}
}
func TestDelegatedIdentityMalformedAndOSSTokens(t *testing.T) {
	for _, payload := range []string{`{}`, `{"iss":"wrong","preferred_username":"bob","act":{"sub":"system:serviceaccount:demo:dba-agent"}}`, `{"iss":"sts.example:7777","preferred_username":"bob","act":{"sub":"not-a-service-account"}}`, `{"iss":"sts.example:7777","preferred_username":"bob","act":"bad"}`} {
		t.Setenv("DELEGATED_ISSUER", "sts.example:7777")
		token := "e30." + base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".fixture"
		user, agent := delegatedIdentity(map[string]string{"authorization": "Bearer " + token})
		if user != "" || agent != "" {
			t.Fatalf("malformed claims produced identity")
		}
	}
	t.Setenv("DELEGATED_ISSUER", "")
	user, agent := delegatedIdentity(map[string]string{"authorization": "Bearer invalid"})
	if user != "" || agent != "" {
		t.Fatal("OSS path produced identity")
	}
	for _, auth := range []string{"", "Basic abc", "Bearer invalid", "Bearer a.!.b"} {
		t.Setenv("DELEGATED_ISSUER", "sts.example:7777")
		user, agent := delegatedIdentity(map[string]string{"Authorization": auth})
		if user != "" || agent != "" {
			t.Fatal("malformed token produced identity")
		}
	}
}
