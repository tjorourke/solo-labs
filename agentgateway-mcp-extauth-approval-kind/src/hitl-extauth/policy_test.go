package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDecide(t *testing.T) {
	p := ServerPolicy{Approve: []string{"delete_user"}}
	cases := []struct {
		name    string
		tool    string
		want    Verdict
		contain string
	}{
		{"handshake", "", VerdictAllow, "not a tools/call"},
		{"approve", "delete_user", VerdictApprove, "approve pattern"},
		{"not listed", "get_users", VerdictAllow, "needs no approval"},
		// Native MCP authorization hides and denies this, not ext-auth.
		{"not listed destructive", "wipe_users", VerdictAllow, "needs no approval"},
		{"no substring", "not_delete_user_either", VerdictAllow, "needs no approval"},
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
	p := ServerPolicy{Approve: []string{"delete_.*", ".*_force"}}
	cases := []struct {
		tool string
		want Verdict
	}{
		{"delete_user", VerdictApprove},
		{"delete_everything", VerdictApprove},
		{"purge_force", VerdictApprove},
		{"get_users", VerdictAllow},
		{"undelete_user", VerdictAllow},
	}
	for _, tc := range cases {
		got, reason := p.decide(tc.tool)
		if got != tc.want {
			t.Fatalf("decide(%q)=%s (%s), want %s", tc.tool, got, reason, tc.want)
		}
	}
}

func TestDecideAllTools(t *testing.T) {
	p := ServerPolicy{Approve: []string{".*"}}
	got, reason := p.decide("anything_from_this_server")
	if got != VerdictApprove {
		t.Fatalf(".* should park every tool, got %s (%s)", got, reason)
	}
}

func TestDecideAnchored(t *testing.T) {
	p := ServerPolicy{Approve: []string{"delete"}}
	got, reason := p.decide("delete_user")
	if got != VerdictAllow {
		t.Fatalf("unanchored substring should not match, got %s (%s)", got, reason)
	}
}

func TestPolicyStoreMissingFileFailsClosed(t *testing.T) {
	s := newPolicyStore(filepath.Join(t.TempDir(), "missing.yaml"))
	got, reason := s.snapshot().decide("users-mcp", "delete_user")
	if got != VerdictDeny {
		t.Fatalf("missing file: got %s (%s), want deny", got, reason)
	}
	if got, _ := s.snapshot().decide("users-mcp", ""); got != VerdictAllow {
		t.Fatalf("missing file: handshake got %s, want allow", got)
	}
}

func TestPolicyStoreEmptyFileFailsClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if got, _ := s.snapshot().decide("users-mcp", "delete_user"); got != VerdictDeny {
		t.Fatalf("empty file: got %s, want deny", got)
	}
	if s.status()["error"] == nil {
		t.Fatal("expected empty file to be reported")
	}
}

func TestPolicyStoreExplicitEmptyParksNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if got, reason := s.snapshot().decide("users-mcp", "delete_user"); got != VerdictAllow {
		t.Fatalf("{}: got %s (%s), want allow", got, reason)
	}
}

func TestPolicyStoreReload(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	got, _ := s.snapshot().decide("users-mcp", "delete_user")
	if got != VerdictAllow {
		t.Fatalf("initial delete_user: got %s, want allow", got)
	}
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve:\n    - delete_.*\n"), 0o644); err != nil {
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
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve:\n    - delete_user\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, reason := s.snapshot().decide("users-mcp", "delete_user")
	if got != VerdictApprove {
		t.Fatalf("after parse error: got %s (%s), want previous approve", got, reason)
	}
	if s.status()["error"] == nil || s.status()["error"] == "" {
		t.Fatal("expected parse error to be reported")
	}
}

func TestPolicyStoreKeepsLastGoodOnBadRegex(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve:\n    - delete_user\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve:\n    - '(unclosed'\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, reason := s.snapshot().decide("users-mcp", "delete_user")
	if got != VerdictApprove {
		t.Fatalf("after bad regex: got %s (%s), want previous approve", got, reason)
	}
	if s.status()["error"] == nil || s.status()["error"] == "" {
		t.Fatal("expected regex error to be reported")
	}
}

func TestServerToolPolicy(t *testing.T) {
	p := ToolPolicy{
		"users-mcp":   {Approve: []string{"delete_.*"}},
		"":            {Approve: []string{".*"}},
		"archive-mcp": {Approve: []string{"purge_.*"}},
	}
	for _, tc := range []struct {
		server, tool string
		want         Verdict
	}{
		{"users-mcp", "delete_user", VerdictApprove},
		// A delete rule under users-mcp does not follow the name to another server.
		{"archive-mcp", "delete_user", VerdictAllow},
		{"archive-mcp", "purge_all", VerdictApprove},
		{"users-mcp", "purge_all", VerdictAllow},
		{"users-mcp", "get_users", VerdictAllow},
		{"users-mcp", "wipe_users", VerdictAllow},
		{"unknown", "delete_user", VerdictAllow},
		// The empty key never matches, even with a catch-all rule.
		{"", "delete_user", VerdictAllow},
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
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [delete_.*]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	policy, ok := s.status()["servers"].(ToolPolicy)
	if !ok || len(policy["users-mcp"].Approve) != 1 {
		t.Fatalf("missing server policy: %v", s.status())
	}
	if _, ok := s.status()["approve"]; ok {
		t.Fatal("legacy flat policy in status")
	}
}

func TestPolicyStoreRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.yaml")
	if err := os.WriteFile(path, []byte("users-mcp:\n  approve: [delete_user]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	s := newPolicyStore(path)
	for _, bad := range []string{
		"users-mcp:\n  aproove: [delete_user]\n",
		// The old lists are gone; a stale ConfigMap must not load silently.
		"users-mcp:\n  allow: [get_.*]\n  approve: [delete_.*]\n  deny: []\n",
	} {
		if err := os.WriteFile(path, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		got, _ := s.snapshot().decide("users-mcp", "delete_user")
		if got != VerdictApprove || s.status()["error"] == nil {
			t.Fatalf("bad schema replaced the last good policy: %q", bad)
		}
	}
}
