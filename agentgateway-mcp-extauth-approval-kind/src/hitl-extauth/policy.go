package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"regexp"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// Verdict is what hitl-extauth should do with one tools/call.
// The approve rules never deny a tool: agentgateway's native MCP
// authorization decides which tools are visible and callable. The only deny
// is fail-closed, when no approve rules have ever loaded.
type Verdict int

const (
	VerdictAllow Verdict = iota
	VerdictApprove
	VerdictDeny
)

func (v Verdict) String() string {
	switch v {
	case VerdictAllow:
		return "allow"
	case VerdictApprove:
		return "approve"
	default:
		return "deny"
	}
}

// ToolPolicy maps an MCP server name to the tools on it that need a reviewer.
type ToolPolicy map[string]ServerPolicy

// ServerPolicy applies only to tools on one MCP server.
// Each entry is a Go regular expression matched against the whole tool name:
// delete_user matches only that tool, delete_.* matches every tool starting
// with delete_, and .* parks every tool from this server.
type ServerPolicy struct {
	Approve []string `json:"approve" yaml:"approve"`
}

func compilePattern(pat string) (*regexp.Regexp, error) {
	return regexp.Compile("^(?:" + pat + ")$")
}

func (p ServerPolicy) compile() error {
	for _, pat := range p.Approve {
		if pat == "" {
			continue
		}
		if _, err := compilePattern(pat); err != nil {
			return fmt.Errorf("approve pattern %q: %w", pat, err)
		}
	}
	return nil
}

// firstMatch returns the first pattern that matches the whole tool name.
func firstMatch(patterns []string, name string) (string, bool) {
	for _, pat := range patterns {
		if pat == "" {
			continue
		}
		re, err := compilePattern(pat)
		if err != nil {
			continue
		}
		if re.MatchString(name) {
			return pat, true
		}
	}
	return "", false
}

// decide returns the verdict for a tool name.
// Handshake frames (empty tool name) always allow, so initialize and
// tools/list are never parked. A name that matches an approve pattern is
// parked. Anything else is allowed here and left to agentgateway's native
// MCP authorization.
func (p ServerPolicy) decide(toolName string) (Verdict, string) {
	if toolName == "" {
		return VerdictAllow, "not a tools/call"
	}
	if pat, ok := firstMatch(p.Approve, toolName); ok {
		return VerdictApprove, fmt.Sprintf("tool %q matched approve pattern %q", toolName, pat)
	}
	return VerdictAllow, fmt.Sprintf("tool %q needs no approval", toolName)
}

// decide selects the server block before matching any tool patterns, so a
// rule under one server never parks the same tool name on another server.
func (p ToolPolicy) decide(server, tool string) (Verdict, string) {
	if tool == "" {
		return VerdictAllow, "not a tools/call"
	}
	if p == nil {
		// Never loaded a valid file: do not let a high-risk call skip review.
		return VerdictDeny, "approve rules not loaded (fail closed)"
	}
	rules, ok := p[server]
	if server == "" || !ok {
		return VerdictAllow, fmt.Sprintf("server %q has no approve rules", server)
	}
	verdict, reason := rules.decide(tool)
	return verdict, fmt.Sprintf("server %q: %s", server, reason)
}

// PolicyStore loads a YAML policy file and re-reads it when the contents change.
type PolicyStore struct {
	path string

	mu       sync.RWMutex
	policy   ToolPolicy
	hash     string
	err      string
	loadedAt time.Time
}

func newPolicyStore(path string) *PolicyStore {
	s := &PolicyStore{path: path}
	s.reload()
	return s
}

func (s *PolicyStore) reload() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		s.mu.Lock()
		s.err = err.Error()
		s.mu.Unlock()
		log.Printf("[policy] failed to read %s: %v (keeping previous approve rules)", s.path, err)
		return
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])

	s.mu.RLock()
	unchanged := hash == s.hash
	s.mu.RUnlock()
	if unchanged {
		return
	}

	var p ToolPolicy
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	err = decoder.Decode(&p)
	if err == nil && p == nil {
		err = fmt.Errorf("no server blocks; use {} to park nothing")
	}
	if err != nil {
		s.mu.Lock()
		s.err = err.Error()
		s.mu.Unlock()
		log.Printf("[policy] failed to parse %s: %v (keeping previous policy)", s.path, err)
		return
	}
	for server, rules := range p {
		if rules.Approve == nil {
			rules.Approve = []string{}
		}
		if err := rules.compile(); err != nil {
			s.mu.Lock()
			s.err = fmt.Sprintf("server %q: %v", server, err)
			s.mu.Unlock()
			log.Printf("[policy] invalid pattern in %s for server %q: %v (keeping previous policy)", s.path, server, err)
			return
		}
		p[server] = rules
	}

	s.mu.Lock()
	s.policy = p
	s.hash = hash
	s.err = ""
	s.loadedAt = time.Now().UTC()
	s.mu.Unlock()
	log.Printf("[policy] loaded %s servers=%v", s.path, p)
}

func (s *PolicyStore) snapshot() ToolPolicy {
	s.reload()
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.policy
}

func (s *PolicyStore) status() map[string]any {
	s.reload()
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := map[string]any{
		"path":     s.path,
		"servers":  s.policy,
		"loadedAt": s.loadedAt,
	}
	if s.err != "" {
		out["error"] = s.err
	}
	return out
}
