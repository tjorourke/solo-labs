package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	ext "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

func valid(t *testing.T) evaluation {
	t.Helper()
	var e evaluation
	err := json.Unmarshal([]byte(`{"model":"jev-test","answers":{"task":{"type":"choice","choice":"code_review","confidence":0.95,"probabilities":{"code_review":0.96,"code_modification":0.01,"generic_coding":0.01,"finance":0.01,"telco":0.01,"uncertain":0}}},"usage":{"input_tokens":101,"output_tokens":22}}`), &e)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func testProfile(t *testing.T) *profile {
	t.Helper()
	raw,err:=os.ReadFile("../config/task-routing.json");if err!=nil{t.Fatal(err)}
	p,err:=loadProfile(raw);if err!=nil{t.Fatal(err)};p.Model="jev-test";return p
}

func TestDecisionContract(t *testing.T) {
	for _, tt := range []struct {
		name, task, state string
		change            func(*evaluation)
		invalid           bool
	}{
		{"coding", "code_review", "classified", func(*evaluation) {}, false},
		{"uncertain", "uncertain", "fallback_choice", func(e *evaluation) {
			a := e.Answers["task"]
			a.Choice = "uncertain"
			a.Probabilities["uncertain"], a.Probabilities["code_review"] = a.Probabilities["code_review"], a.Probabilities["uncertain"]
			e.Answers["task"] = a
		}, false},
		{"low confidence", "uncertain", "low_confidence", func(e *evaluation) { *e.Answers["task"].Confidence = 0.2 }, false},
		{"close alternatives", "uncertain", "low_confidence", func(e *evaluation) {
			*e.Answers["task"].Probabilities["code_review"] = 0.49
			*e.Answers["task"].Probabilities["code_modification"] = 0.48
		}, false},
		{"missing confidence", "", "", func(e *evaluation) { a := e.Answers["task"]; a.Confidence = nil; e.Answers["task"] = a }, true},
		{"missing label", "", "", func(e *evaluation) { delete(e.Answers["task"].Probabilities, "telco") }, true},
		{"null probability", "", "", func(e *evaluation) { e.Answers["task"].Probabilities["telco"] = nil }, true},
		{"bad sum", "", "", func(e *evaluation) { *e.Answers["task"].Probabilities["telco"] = 0.9 }, true},
		{"wrong winner", "", "", func(e *evaluation) { a := e.Answers["task"]; a.Choice = "finance"; e.Answers["task"] = a }, true},
		{"unknown label", "", "", func(e *evaluation) { a := e.Answers["task"]; a.Choice = "frontier"; e.Answers["task"] = a }, true},
		{"confidence out of range", "", "", func(e *evaluation) { *e.Answers["task"].Confidence = 1.1 }, true},
		{"missing usage", "", "", func(e *evaluation) { e.Usage = nil }, true},
		{"missing model", "", "", func(e *evaluation) { e.Model = "" }, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := valid(t)
			tt.change(&e)
			d, err := decide(e, testProfile(t))
			if (err != nil) != tt.invalid {
				t.Fatalf("error=%v", err)
			}
			if err == nil && (d.Task != tt.task || d.Status != tt.state) {
				t.Fatalf("decision=%+v", d)
			}
		})
	}
}

func TestUnsupportedInputNeverClassified(t *testing.T) {
	for _, body := range []string{
		`{"model":"kb-coding","messages":[{"role":"user","content":"hi"}]}`,
		`{"model":"auto","messages":[{"role":"user","content":"hi"}],"stream":true}`,
		`{"model":"auto","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com"}}]}]}`,
		`{"model":"auto","messages":[{"role":"user","content":"hi"}],"tools":[]}`,
		`{"model":"auto","messages":[{"role":"system","content":"hi"}]}`,
		`{"model":"auto","messages":[{"role":"user","content":"hi"},{"role":"user","content":"bye"}]}`,
		`{"model":"auto","messages":[{"role":"user","content":"hi"}]} {}`,
		strings.Repeat("x", maxBody+1),
	} {
		if _, err := parseChat([]byte(body)); err == nil {
			t.Fatal("accepted unsupported input")
		}
	}
}

func rpc(t *testing.T, p *processor) ext.ExternalProcessor_ProcessClient {
	t.Helper()
	lis := bufconn.Listen(1024 * 1024)
	s := grpc.NewServer()
	ext.RegisterExternalProcessorServer(s, p)
	go func() { _ = s.Serve(lis) }()
	t.Cleanup(s.Stop)
	conn, err := grpc.NewClient("passthrough:///memory", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	stream, err := ext.NewExternalProcessorClient(conn).Process(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return stream
}

func sendHeaders(t *testing.T, s ext.ExternalProcessor_ProcessClient) {
	t.Helper()
	err := s.Send(&ext.ProcessingRequest{Request: &ext.ProcessingRequest_RequestHeaders{RequestHeaders: &ext.HttpHeaders{Headers: &core.HeaderMap{Headers: []*core.HeaderValue{{Key: ":method", RawValue: []byte("POST")}, {Key: ":path", RawValue: []byte("/v1/chat/completions")}, {Key: "x-jev-task", RawValue: []byte("generic_coding")}}}}}})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if len(r.GetRequestHeaders().GetResponse().GetHeaderMutation().GetRemoveHeaders()) != len(ownedHeaders) {
		t.Fatal("client routing headers were not removed")
	}
}

func sendBody(t *testing.T, s ext.ExternalProcessor_ProcessClient, body string) *ext.ProcessingResponse {
	t.Helper()
	if err := s.Send(&ext.ProcessingRequest{Request: &ext.ProcessingRequest_RequestBody{RequestBody: &ext.HttpBody{Body: []byte(body), EndOfStream: true}}}); err != nil {
		t.Fatal(err)
	}
	r, err := s.Recv()
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestExtProcRoundTrip(t *testing.T) {
	var calls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var payload struct {
			State     string          `json:"state"`
			Model     string          `json:"model"`
			Questions json.RawMessage `json:"questions"`
		}
		if json.NewDecoder(r.Body).Decode(&payload) != nil || payload.State != "Review this synthetic function" || payload.Model != "jev-test" || r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("wrong upstream contract")
		}
		if !strings.Contains(string(payload.Questions), "criteria") {
			t.Error("missing choice question")
		}
		_ = json.NewEncoder(w).Encode(valid(t))
	}))
	defer provider.Close()
	s := rpc(t, &processor{url: provider.URL, key: "test-key", profile: testProfile(t), client: provider.Client()})
	sendHeaders(t, s)
	r := sendBody(t, s, `{"model":"auto","messages":[{"role":"user","content":"Review this synthetic function"}]}`)
	m := r.GetRequestBody().GetResponse()
	if m.GetBodyMutation() != nil {
		t.Fatal("classifier changed the original request body")
	}
	if string(m.GetHeaderMutation().GetSetHeaders()[0].Header.RawValue) != "code_review" {
		t.Fatal("wrong task header")
	}
	if err := s.Send(&ext.ProcessingRequest{Request: &ext.ProcessingRequest_ResponseHeaders{ResponseHeaders: &ext.HttpHeaders{}}}); err != nil {
		t.Fatal(err)
	}
	r, err := s.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if string(r.GetResponseHeaders().GetResponse().GetHeaderMutation().GetSetHeaders()[0].Header.RawValue) != "code_review" {
		t.Fatal("response lost the decision")
	}
	_ = s.CloseSend()
	if _, err := s.Recv(); err != io.EOF {
		t.Fatalf("stream close: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatal("expected exactly one paid request")
	}
}

func TestProviderFailureStopsRequest(t *testing.T) {
	for _, mode := range []string{"401", "429", "malformed", "timeout", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int32
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				switch mode {
				case "401":
					w.WriteHeader(401)
				case "429":
					w.WriteHeader(429)
				case "timeout":
					time.Sleep(60 * time.Millisecond)
				case "redirect":
					http.Redirect(w, r, "/elsewhere", 302)
				default:
					_, _ = w.Write([]byte(`{"answers":null}`))
				}
			}))
			defer provider.Close()
			client := provider.Client()
			client.Timeout = 20 * time.Millisecond
			client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
			s := rpc(t, &processor{url: provider.URL, key: "test-key", profile: testProfile(t), client: client})
			sendHeaders(t, s)
			r := sendBody(t, s, `{"model":"auto","messages":[{"role":"user","content":"hello"}]}`)
			if r.GetImmediateResponse().GetStatus().GetCode() != 503 {
				t.Fatalf("failure was not a 503: %v", r)
			}
			if calls.Load() != 1 {
				t.Fatal("unexpected retry")
			}
		})
	}
}

func TestMalformedRequestMakesNoProviderCall(t *testing.T) {
	s := rpc(t, &processor{}) // Any upstream use would panic: input must be rejected first.
	sendHeaders(t, s)
	r := sendBody(t, s, `{"model":"auto","messages":[],"stream":true}`)
	if r.GetImmediateResponse().GetStatus().GetCode() != 400 {
		t.Fatal("expected input rejection")
	}
}

func TestFixtureVerifiesBackendModel(t *testing.T) {
	for _, model := range []string{"kb-coding", "kb-general"} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(`{"model":"`+model+`","messages":[]}`))
		fixture("kb-coding").ServeHTTP(w, r)
		want := 200
		if model != "kb-coding" {
			want = 400
		}
		if w.Code != want {
			t.Fatalf("got %d", w.Code)
		}
	}
}
