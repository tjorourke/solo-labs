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
	case VerdictDeny:
		return "deny"
	default:
		return "deny"
	}
}

// ToolPolicy maps an MCP server name to its own tool rules.
type ToolPolicy map[string]ServerPolicy

// ServerPolicy applies only to tools on one MCP server.
// Each entry is a Go regular expression matched against the whole tool name:
// get_users matches only that tool, get_.* matches every tool starting with
// get_, and .* matches every tool (for example every tool from this server).
type ServerPolicy struct {
	Allow   []string `json:"allow" yaml:"allow"`
	Approve []string `json:"approve" yaml:"approve"`
	Deny    []string `json:"deny" yaml:"deny"`
}

func compilePattern(pat string) (*regexp.Regexp, error) {
	return regexp.Compile("^(?:" + pat + ")$")
}

func (p ServerPolicy) compile() error {
	for _, list := range []struct {
		name     string
		patterns []string
	}{
		{"allow", p.Allow},
		{"approve", p.Approve},
		{"deny", p.Deny},
	} {
		for _, pat := range list.patterns {
			if pat == "" {
				continue
			}
			if _, err := compilePattern(pat); err != nil {
				return fmt.Errorf("%s pattern %q: %w", list.name, pat, err)
			}
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
// tools/list are never parked. Precedence is deny, then approve, then
// allow. A name that matches none of the lists is denied.
func (p ServerPolicy) decide(toolName string) (Verdict, string) {
	if toolName == "" {
		return VerdictAllow, "not a tools/call"
	}
	if pat, ok := firstMatch(p.Deny, toolName); ok {
		return VerdictDeny, fmt.Sprintf("tool %q matched deny pattern %q", toolName, pat)
	}
	if pat, ok := firstMatch(p.Approve, toolName); ok {
		return VerdictApprove, fmt.Sprintf("tool %q matched approve pattern %q", toolName, pat)
	}
	if pat, ok := firstMatch(p.Allow, toolName); ok {
		return VerdictAllow, fmt.Sprintf("tool %q matched allow pattern %q", toolName, pat)
	}
	return VerdictDeny, fmt.Sprintf("tool %q is not listed (default deny)", toolName)
}

// decide selects the server block before matching any tool patterns.
func (p ToolPolicy) decide(server, tool string) (Verdict, string) {
	if tool == "" {
		return VerdictAllow, "not a tools/call"
	}
	rules, ok := p[server]
	if server == "" || !ok {
		return VerdictDeny, fmt.Sprintf("server %q is not listed (default deny)", server)
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
		if s.hash == "" {
			s.policy = ToolPolicy{}
		}
		s.err = err.Error()
		s.mu.Unlock()
		log.Printf("[policy] failed to read %s: %v (unlisted tools default to deny)", s.path, err)
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
	if err := decoder.Decode(&p); err != nil {
		s.mu.Lock()
		s.err = err.Error()
		s.mu.Unlock()
		log.Printf("[policy] failed to parse %s: %v (keeping previous policy)", s.path, err)
		return
	}
	for server, rules := range p {
		if rules.Allow == nil {
			rules.Allow = []string{}
		}
		if rules.Approve == nil {
			rules.Approve = []string{}
		}
		if rules.Deny == nil {
			rules.Deny = []string{}
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
