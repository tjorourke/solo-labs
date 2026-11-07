package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDecide(t *testing.T) {
	p := ServerPolicy{
		Allow:   []string{"get_users"},
		Approve: []string{"delete_user"},
		Deny:    []string{"wipe_db"},
	}
	cases := []struct {
		name    string
		tool    string
		want    Verdict
		contain string
	}{
		{"handshake", "", VerdictAllow, "not a tools/call"},
		{"allow", "get_users", VerdictAllow, "allow pattern"},
		{"approve", "delete_user", VerdictApprove, "approve pattern"},
		{"deny", "wipe_db", VerdictDeny, "deny pattern"},
		{"unlisted", "get_everything", VerdictDeny, "default deny"},
		{"no substring", "not_get_users_either", VerdictDeny, "default deny"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, reason := p.decide(tc.tool)
			if got != tc.want {
				t.Fatalf("decide(%q)=%s, want %s (%s)", tc.tool, got, tc.want, reason)
			}
			if tc.contain != "" && !strings.Contains(reason, tc.contain) {
				t.Fatalf("reason %q does not contain %q", reason, tc.contain)
			}
		})
	}
}

func TestDecideRegex(t *testing.T) {
	p := ServerPolicy{
		Allow:   []string{"get_.*"},
		Approve: []string{".*delete.*"},
		Deny:    []string{"wipe_.*"},
	}
	cases := []struct {
		tool string
		want Verdict
	}{
		{"get_users", VerdictAllow},
		{"get_everything", VerdictAllow},
		{"delete_user", VerdictApprove},
		{"force_delete", VerdictApprove},
		{"wipe_db", VerdictDeny},
		{"list_accounts", VerdictDeny},
	}
	for _, tc := range cases {
		got, reason := p.decide(tc.tool)
		if got != tc.want {
			t.Fatalf("decide(%q)=%s (%s), want %s", tc.tool, got, reason, tc.want)
		}
	}
}

func TestDecideAllTools(t *testing.T) {
	p := ServerPolicy{Allow: []string{".*"}}
	got, reason := p.decide("anything_from_this_server")
	if got != VerdictAllow {
		t.Fatalf(".* should allow every tool, got %s (%s)", got, reason)
	}
}

func TestDecideAnchored(t *testing.T) {
	p := ServerPolicy{Allow: []string{"users"}}
	got, reason := p.decide("get_users")
	if got != VerdictDeny {
		t.Fatalf("unanchored substring should not match, got %s (%s)", got, reason)
	}
}

func TestDecideDenyWins(t *testing.T) {
	p := ServerPolicy{
		Allow:   []string{".*"},
		Approve: []string{".*"},
		Deny:    []string{"delete_user"},
	}
	got, reason := p.decide("delete_user")
	if got != VerdictDeny {
		t.Fatalf("got %s (%s), want deny", got, reason)
	}
}

func TestPolicyStoreMissingFileDefaultsDeny(t *testing.T) {
	s := newPolicyStore(filepath.Join(t.TempDir(), "missing.yaml"))
	got, reason := s.snapshot().decide("users-mcp", "get_users")
	if got != VerdictDeny {
		t.Fatalf("missing file: got %s (%s), want deny", got, reason)
	}
}

func TestPolicyStoreReload(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow:\n    - get_.*\n  approve: []\n  deny: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	got, _ := s.snapshot().decide("users-mcp", "get_users")
	if got != VerdictAllow {
		t.Fatalf("initial get_users: got %s, want allow", got)
	}
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow: []\n  approve:\n    - delete_.*\n  deny: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	got, reason := s.snapshot().decide("users-mcp", "delete_user")
	if got != VerdictApprove {
		t.Fatalf("reloaded delete_user: got %s (%s), want approve", got, reason)
	}
}

func TestPolicyStoreKeepsLastGoodOnParseError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow:\n    - get_users\n  approve: []\n  deny: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow: [\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, reason := s.snapshot().decide("users-mcp", "get_users")
	if got != VerdictAllow {
		t.Fatalf("after parse error: got %s (%s), want previous allow", got, reason)
	}
	if s.status()["error"] == nil || s.status()["error"] == "" {
		t.Fatal("expected parse error to be reported")
	}
}

func TestPolicyStoreKeepsLastGoodOnBadRegex(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow:\n    - get_users\n  approve: []\n  deny: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow:\n    - '(unclosed'\n  approve: []\n  deny: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, reason := s.snapshot().decide("users-mcp", "get_users")
	if got != VerdictAllow {
		t.Fatalf("after bad regex: got %s (%s), want previous allow", got, reason)
	}
	if s.status()["error"] == nil || s.status()["error"] == "" {
		t.Fatal("expected regex error to be reported")
	}
}

func TestServerToolPolicy(t *testing.T) {
	p := ToolPolicy{
		"users-mcp":   {Allow: []string{"get_.*"}, Approve: []string{"delete_.*"}},
		"":            {Allow: []string{".*"}},
		"archive-mcp": {Allow: []string{"delete_.*"}},
	}
	for _, tc := range []struct {
		server, tool string
		want         Verdict
	}{
		{"users-mcp", "delete_user", VerdictApprove},
		{"archive-mcp", "delete_user", VerdictAllow},
		{"users-mcp", "get_users", VerdictAllow},
		{"unknown", "delete_user", VerdictDeny},
		{"", "delete_user", VerdictDeny},
		{"users-mcp", "wipe_users", VerdictDeny},
		{"unknown", "", VerdictAllow},
	} {
		t.Run(tc.server+"/"+tc.tool, func(t *testing.T) {
			got, reason := p.decide(tc.server, tc.tool)
			if got != tc.want {
				t.Fatalf("got %s (%s), want %s", got, reason, tc.want)
			}
		})
	}
}
func TestPolicyStatusHasServerBlocks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow: [get_.*]\n  approve: [delete_.*]\n  deny: []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	policy, ok := s.status()["servers"].(ToolPolicy)
	if !ok || len(policy["users-mcp"].Approve) != 1 {
		t.Fatalf("missing server policy: %v", s.status())
	}
	if _, ok := s.status()["allow"]; ok {
		t.Fatal("legacy flat policy in status")
	}
}

func TestPolicyStoreRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  allow: [get_users]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if err := os.WriteFile(path, []byte("users-mcp:\n  aproove: [delete_user]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, _ := s.snapshot().decide("users-mcp", "get_users")
	if got != VerdictAllow || s.status()["error"] == nil {
		t.Fatal("bad schema replaced the last good policy")
	}
}
