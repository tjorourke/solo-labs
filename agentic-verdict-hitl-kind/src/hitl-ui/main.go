// hitl-ui — single-page approval queue that polls hitl-extauth's admin HTTP
// API and renders each parked request as a card with Approve / Reject buttons.
//
// HTMX-driven: the page loads once, then polls /pending-list every 8s for an
// HTML fragment of the current queue. Decide buttons POST /decide/{id}/{action}
// which proxies to the upstream extauth admin.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"sort"
	"time"
)

type Pending struct {
	ID         string            `json:"id"`
	ReceivedAt time.Time         `json:"receivedAt"`
	Method     string            `json:"method"`
	Path       string            `json:"path"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
	RPCMethod  string            `json:"rpcMethod"`
	ToolName   string            `json:"toolName"`
	ToolArgs   map[string]any    `json:"toolArgs"`
}

type pendingResponse struct {
	Pending []Pending `json:"pending"`
}

type server struct {
	upstream string
	client   *http.Client
	tmpl     *template.Template
}

// ─── HTTP handlers ────────────────────────────────────────────────────────────

func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = s.tmpl.ExecuteTemplate(w, "index", nil)
}

func (s *server) list(w http.ResponseWriter, r *http.Request) {
	pending, err := s.fetchPending(r.Context())
	if err != nil {
		http.Error(w, fmt.Sprintf("upstream error: %v", err), http.StatusBadGateway)
		return
	}
	// Oldest first — feels more natural in a queue.
	sort.Slice(pending, func(i, j int) bool { return pending[i].ReceivedAt.Before(pending[j].ReceivedAt) })
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = s.tmpl.ExecuteTemplate(w, "list", pending)
}

func (s *server) decide(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	action := r.PathValue("action")
	approved := action == "approve"
	reason := r.FormValue("reason")
	if reason == "" {
		if approved {
			reason = "approved by reviewer"
		} else {
			reason = "rejected by reviewer"
		}
	}
	body, _ := json.Marshal(map[string]any{"approved": approved, "reason": reason})
	req, err := http.NewRequestWithContext(r.Context(), "POST",
		s.upstream+"/decide/"+id, bytes.NewReader(body))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf("upstream error: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		http.Error(w, fmt.Sprintf("upstream %s", resp.Status), resp.StatusCode)
		return
	}
	// Re-render the list so HTMX can swap it in.
	s.list(w, r)
}

func (s *server) fetchPending(ctx context.Context) ([]Pending, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", s.upstream+"/pending", nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("upstream %s", resp.Status)
	}
	var pr pendingResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, err
	}
	return pr.Pending, nil
}

// ─── Templates (inline so this is a single-file build) ────────────────────────

var tmplSrc = `
{{ define "index" -}}
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DBA Ops · Platform Approval Queue</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <script src="https://unpkg.com/htmx.org@2.0.3"></script>
  <style>
    :root {
      --bg: #0b0f17; --panel: #131a26; --panel-2: #1a2333; --border: #243044;
      --text: #e5edf6; --muted: #8aa0bd; --dim: #64748b;
      --accent: #67e8f9; --ok: #34d399; --warn: #f59e0b; --danger: #f87171;
      --code: #0f1622;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           background:
             radial-gradient(circle at 20% 0%, rgba(245,158,11,0.06), transparent 50%),
             radial-gradient(circle at 80% 100%, rgba(103,232,249,0.04), transparent 50%),
             var(--bg);
           color: var(--text); min-height: 100vh; }
    header { padding: 1.4rem 1.6rem 1.2rem; border-bottom: 1px solid var(--border); }
    .header-row { display: flex; align-items: center; justify-content: space-between; gap: 1rem; max-width: 1040px; margin: 0 auto; }
    .brand { display: flex; align-items: center; gap: 0.8rem; }
    .brand svg { flex: 0 0 auto; }
    .brand h1 { margin: 0; font-size: 1.05rem; font-weight: 600; letter-spacing: -0.01em; }
    .brand .role-tag { display:inline-block; background: rgba(245,158,11,0.10); color: var(--warn);
                       border: 1px solid rgba(245,158,11,0.25); border-radius: 999px;
                       padding: 0.15rem 0.55rem; font-size: 0.7rem; font-weight: 600;
                       letter-spacing: 0.06em; margin-left: 0.45rem; vertical-align: middle; }
    .brand .sub { color: var(--muted); font-size: 0.82rem; margin-top: 0.2rem; }
    .live { display: inline-flex; align-items: center; gap: 0.4rem; color: var(--muted); font-size: 0.78rem; }
    .live .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok);
                 box-shadow: 0 0 0 0 rgba(52,211,153,0.7); animation: pulse 1.6s infinite; }
    @keyframes pulse { 70% { box-shadow: 0 0 0 10px rgba(52,211,153,0); } 100% { box-shadow: 0 0 0 0 rgba(52,211,153,0); } }
    .crumbs { font-size: 0.74rem; color: var(--dim); margin-top: 0.5rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .crumbs code { color: var(--muted); }
    main { padding: 1.4rem 1.6rem; max-width: 1040px; margin: 0 auto; }
    .empty { color: var(--muted); text-align: center; padding: 3.5rem 1rem; font-size: 0.95rem; }
    .empty strong { color: var(--text); }
    .empty .hint { display:block; margin-top: 0.7rem; font-size: 0.82rem; color: var(--dim); }
    .card { background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
            margin-bottom: 1rem; overflow: hidden; }
    .card.privileged { border-color: rgba(245,158,11,0.35);
                       box-shadow: 0 0 0 1px rgba(245,158,11,0.08) inset; }
    .card.protocol { border-color: rgba(100,116,139,0.35); opacity: 0.78; }
    .card-bar { display: flex; align-items: center; justify-content: space-between;
                padding: 0.5rem 1rem; background: var(--panel-2);
                border-bottom: 1px solid var(--border); font-size: 0.74rem;
                letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
    .card.privileged .card-bar { color: var(--warn); }
    .card.protocol .card-bar { color: var(--dim); text-transform: none; letter-spacing: 0; }
    .card-bar .right { color: var(--dim); font-weight: 400; letter-spacing: 0;
                       text-transform: none; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                       font-size: 0.74rem; }
    .card-body { padding: 1rem 1.2rem 1.1rem; }
    .title { font-size: 1.2rem; font-weight: 600; margin: 0 0 0.2rem; letter-spacing: -0.01em; }
    .subtitle { font-size: 0.85rem; color: var(--muted); margin: 0 0 0.85rem; }
    .subtitle code { background: rgba(255,255,255,0.04); padding: 0.05rem 0.35rem; border-radius: 3px;
                     font-size: 0.82rem; }
    .migration { display: grid; grid-template-columns: 1fr auto 1fr; gap: 0.6rem;
                 align-items: center; margin: 0.5rem 0 1rem; }
    .schema-pill { background: var(--code); border: 1px solid var(--border); border-radius: 8px;
                   padding: 0.5rem 0.7rem; text-align: center; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .schema-pill .label { display: block; font-size: 0.65rem; color: var(--dim);
                          text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 0.2rem; }
    .schema-pill .ver { font-size: 1.05rem; font-weight: 600; color: var(--text); }
    .schema-pill.to .ver { color: var(--warn); }
    .arrow { color: var(--warn); font-size: 1.4rem; font-weight: 600; text-align: center; }
    .args { background: var(--code); border-radius: 6px; padding: 0.55rem 0.75rem;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem;
            white-space: pre-wrap; word-break: break-word; margin: 0 0 0.9rem;
            border: 1px solid var(--border); color: var(--accent); }
    .args-label { font-size: 0.7rem; color: var(--dim); text-transform: uppercase;
                  letter-spacing: 0.08em; margin: 0 0 0.3rem; }
    .ctx-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
                gap: 0.5rem 1.2rem; margin: 0.4rem 0 1rem; font-size: 0.82rem; }
    .ctx-grid .k { color: var(--dim); display: block; font-size: 0.7rem;
                   text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 0.15rem; }
    .ctx-grid .v { color: var(--text); font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                   font-size: 0.82rem; word-break: break-all; }
    .risk { background: rgba(245,158,11,0.08); border: 1px solid rgba(245,158,11,0.25);
            color: var(--warn); border-radius: 6px; padding: 0.5rem 0.75rem;
            font-size: 0.8rem; margin: 0 0 1rem; line-height: 1.45; }
    .risk strong { color: var(--text); }
    details { margin: 0.6rem 0 0; font-size: 0.85rem; }
    details summary { cursor: pointer; color: var(--muted); font-size: 0.8rem;
                      padding: 0.2rem 0; user-select: none; }
    details summary:hover { color: var(--text); }
    details pre { background: var(--code); border-radius: 6px; padding: 0.65rem 0.8rem;
                  overflow-x: auto; font-size: 0.78rem; margin: 0.4rem 0 0;
                  border: 1px solid var(--border); color: var(--muted); }
    .reason-row { margin: 1rem 0 0; }
    .reason-row label { display: block; font-size: 0.7rem; color: var(--dim);
                        text-transform: uppercase; letter-spacing: 0.08em;
                        margin: 0 0 0.3rem; }
    .reason-row input { width: 100%; background: var(--code); border: 1px solid var(--border);
                        border-radius: 6px; padding: 0.55rem 0.75rem; color: var(--text);
                        font: inherit; font-size: 0.88rem; }
    .reason-row input:focus { outline: none; border-color: var(--accent); }
    .reason-row .hint { font-size: 0.72rem; color: var(--dim); margin: 0.3rem 0 0;
                        font-style: italic; }
    .actions { display: flex; gap: 0.6rem; margin-top: 0.8rem; }
    button { font: inherit; padding: 0.55rem 1.1rem; border-radius: 6px; border: 1px solid transparent;
             cursor: pointer; font-weight: 600; font-size: 0.88rem; transition: background 0.12s, transform 0.05s; }
    button:active { transform: translateY(1px); }
    button.approve { background: var(--ok); color: #062418; }
    button.approve:hover { background: #6ce0a8; }
    button.reject { background: transparent; color: var(--danger); border-color: var(--danger); }
    button.reject:hover { background: rgba(248,113,113,0.1); }
    .proto-line { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                  font-size: 0.85rem; color: var(--muted); margin: 0; }
    .proto-line .method { color: var(--accent); }
    .proto-line .note { color: var(--dim); margin-left: 0.5rem; font-style: italic; }
    footer { padding: 1.2rem 1.6rem 1.6rem; color: var(--dim); font-size: 0.72rem; text-align: center;
             border-top: 1px solid var(--border); margin-top: 2rem; }
    footer code { color: var(--muted); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  </style>
</head>
<body>
  <header>
    <div class="header-row">
      <div class="brand">
        <!-- A small "DB + gate" mark -->
        <svg width="34" height="34" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
          <ellipse cx="11" cy="9"  rx="7.5" ry="2.6" fill="none" stroke="#f59e0b" stroke-width="1.6"/>
          <path d="M 3.5 9 V 22 C 3.5 23.4 7 24.6 11 24.6 C 15 24.6 18.5 23.4 18.5 22 V 9"
                fill="none" stroke="#f59e0b" stroke-width="1.6"/>
          <path d="M 3.5 14.5 C 3.5 15.9 7 17.1 11 17.1 C 15 17.1 18.5 15.9 18.5 14.5"
                fill="none" stroke="#f59e0b" stroke-width="1.2" opacity="0.7"/>
          <!-- gate / shield -->
          <path d="M 22 11 L 28 13 V 19 C 28 23 25 25.5 22 26.5 C 19 25.5 16 23 16 19 V 13 Z"
                fill="#0b0f17" stroke="#f59e0b" stroke-width="1.6"/>
          <path d="M 19 18.5 L 21.5 21 L 25 16.5" fill="none" stroke="#f59e0b" stroke-width="1.6"
                stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        <div>
          <h1>DBA Operations <span class="role-tag">PLATFORM REVIEW</span></h1>
          <div class="sub">Privileged schema changes parked at the gateway — awaiting platform approval</div>
          <div class="crumbs">
            <code>agentgateway-system/hitl-gateway</code> → ext-auth gate on <code>/privileged/mcp</code>
          </div>
        </div>
      </div>
      <div class="live"><span class="dot"></span>polling every 8s</div>
    </div>
  </header>
  <main>
    <div id="list" hx-get="/pending-list" hx-trigger="load, every 8s" hx-swap="innerHTML">
      <div class="empty">Loading…</div>
    </div>
  </main>
  <footer>
    Sample web app — not a Solo product. Talks to <code>hitl-extauth</code> admin API.
    <br>solo-demos · agentic-hitl-kind
  </footer>
</body>
</html>
{{- end }}

{{ define "list" -}}
{{ if not . -}}
  <div class="empty">
    <strong>No pending operations.</strong>
    <span class="hint">Ask the agent <em>"Apply migration v3"</em> in the kagent chat — it'll show up here for approval.</span>
  </div>
{{- else -}}
  {{ range . }}
  {{ $tier := classify . }}
  <div class="card {{ $tier }}">
    {{ if eq $tier "privileged" }}
      <div class="card-bar">
        <span>● Privileged operation · gateway HITL</span>
        <span class="right">id={{ .ID }} · received {{ .ReceivedAt.Format "15:04:05" }}</span>
      </div>
      <div class="card-body">
        {{ if eq .ToolName "run_migration" }}
          <h2 class="title">Schema migration</h2>
          <p class="subtitle">Agent <code>{{ callerAgent .Headers }}</code> requests <code>run_migration</code> against the orders DB.</p>
          <div class="migration">
            <div class="schema-pill from">
              <span class="label">Current</span>
              <span class="ver">orders.{{ currentSchema }}</span>
            </div>
            <div class="arrow">→</div>
            <div class="schema-pill to">
              <span class="label">Requested</span>
              <span class="ver">orders.{{ index .ToolArgs "version" }}</span>
            </div>
          </div>
        {{ else }}
          <h2 class="title">{{ .ToolName }}</h2>
          <p class="subtitle">Agent <code>{{ callerAgent .Headers }}</code> requests <code>{{ .ToolName }}</code> on a gated tool.</p>
        {{ end }}

        <div class="args-label">Tool arguments</div>
        <div class="args">{{ argsPretty .ToolArgs }}</div>

        <div class="ctx-grid">
          <div><span class="k">Route</span><span class="v">{{ .Path }}</span></div>
          <div><span class="k">Caller agent</span><span class="v">{{ callerAgent .Headers }}</span></div>
          <div><span class="k">JSON-RPC</span><span class="v">{{ .RPCMethod }}</span></div>
        </div>

        <div class="risk">
          <strong>Risk:</strong> mutates live DB schema. Approval is logged in the ext-auth journal and the orders DB audit table. Reject if you're unsure — the agent will surface the denial verbatim, no retry.
        </div>

        <details>
          <summary>request headers + raw body</summary>
          <pre>{{ headersBlock .Headers }}{{ if .Body }}

body:
{{ .Body }}{{ end }}</pre>
        </details>

        <div class="reason-row">
          <label for="reason-{{ .ID }}">Reason (logged in the ext-auth audit trail)</label>
          <input type="text" id="reason-{{ .ID }}" name="reason"
                 placeholder="e.g. approved per change ticket CHG-1234 — or — denied: schema freeze in effect">
          <p class="hint">Optional. The agent shows this verbatim back to the end user on rejection.</p>
        </div>
        <div class="actions">
          <button class="approve"
                  hx-post="/decide/{{ .ID }}/approve"
                  hx-include="#reason-{{ .ID }}"
                  hx-target="#list" hx-swap="innerHTML">Approve migration</button>
          <button class="reject"
                  hx-post="/decide/{{ .ID }}/reject"
                  hx-include="#reason-{{ .ID }}"
                  hx-target="#list" hx-swap="innerHTML">Reject</button>
        </div>
      </div>
    {{ else }}
      {{/* protocol traffic — initialize / tools/list / etc. — not a real approval */}}
      <div class="card-bar">
        <span>MCP protocol traffic (not a tool call)</span>
        <span class="right">id={{ .ID }} · {{ .ReceivedAt.Format "15:04:05" }}</span>
      </div>
      <div class="card-body">
        <p class="proto-line">
          <span class="method">{{ if .RPCMethod }}{{ .RPCMethod }}{{ else }}(unparseable JSON-RPC){{ end }}</span>
          on <code>{{ .Path }}</code>
          <span class="note">— protocol-level call, not a tools/call. Approve to let it through, reject to fail the agent's MCP session.</span>
        </p>
        <details>
          <summary>request headers + raw body</summary>
          <pre>{{ headersBlock .Headers }}{{ if .Body }}

body:
{{ .Body }}{{ end }}</pre>
        </details>
        <div class="actions">
          <button class="approve" hx-post="/decide/{{ .ID }}/approve" hx-target="#list" hx-swap="innerHTML">Approve</button>
          <button class="reject"  hx-post="/decide/{{ .ID }}/reject"  hx-target="#list" hx-swap="innerHTML">Reject</button>
        </div>
      </div>
    {{ end }}
  </div>
  {{ end }}
{{- end }}
{{- end }}
`

func mustTemplate() *template.Template {
	return template.Must(template.New("").Funcs(template.FuncMap{
		"argsPretty": func(args map[string]any) string {
			if len(args) == 0 {
				return "{}"
			}
			b, err := json.MarshalIndent(args, "", "  ")
			if err != nil {
				return fmt.Sprintf("%v", args)
			}
			return string(b)
		},
		"headersBlock": func(h map[string]string) string {
			if len(h) == 0 {
				return ""
			}
			keys := make([]string, 0, len(h))
			for k := range h {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			var buf bytes.Buffer
			for _, k := range keys {
				fmt.Fprintf(&buf, "%s: %s\n", k, h[k])
			}
			return buf.String()
		},
		// classify routes a parked request to a UI tier so the template can
		// render real tools/call invocations with the full DBA-ops treatment
		// and de-emphasize protocol traffic (initialize, tools/list).
		"classify": func(p Pending) string {
			if p.ToolName != "" {
				return "privileged"
			}
			return "protocol"
		},
		// callerAgent picks a best-effort caller identity from common headers.
		// The agent's HTTP client may or may not set user-agent — fall back to
		// 'unknown' so the UI never goes blank.
		"callerAgent": func(h map[string]string) string {
			for _, k := range []string{"user-agent", "x-kagent-agent", "x-forwarded-for"} {
				if v := h[k]; v != "" {
					return v
				}
			}
			return "unknown"
		},
		// currentSchema is hardcoded to the ops-tools default ("v2"). The mock
		// DB starts at v2 every restart; the demo's whole point is migrating to
		// v3. If you wire the UI to query ops-tools /state this becomes live.
		"currentSchema": func() string { return "v2" },
	}).Parse(tmplSrc))
}

// ─── entrypoint ───────────────────────────────────────────────────────────────

func main() {
	upstream := getenv("HITL_EXTAUTH_ADMIN_URL", "http://hitl-extauth-admin.hitl.svc.cluster.local:8081")
	addr := ":" + getenv("HTTP_PORT", "8080")

	s := &server{
		upstream: upstream,
		client:   &http.Client{Timeout: 5 * time.Second},
		tmpl:     mustTemplate(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.index)
	mux.HandleFunc("GET /pending-list", s.list)
	mux.HandleFunc("POST /decide/{id}/{action}", s.decide)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })

	log.Printf("hitl-ui addr=%s upstream=%s", addr, upstream)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
