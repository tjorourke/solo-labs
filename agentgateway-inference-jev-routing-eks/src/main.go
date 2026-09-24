// Reference adapter for the Part 5 KB. This is a single-turn, synthetic-input
// experiment, not a replacement for Part 4's identity and data-handling policy.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	ext "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	types "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const endpoint = "https://api.typesafe.ai/v1/systemone"
const maxBody = 32768

var ownedHeaders = []string{"x-jev-task", "x-jev-choice", "x-jev-status", "x-jev-confidence", "x-jev-margin", "x-jev-model", "x-jev-ms", "x-jev-input-tokens", "x-jev-output-tokens", "x-jev-profile"}

type chatRequest struct {
	Model    string `json:"model"`
	Messages []struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	} `json:"messages"`
	Stream      bool    `json:"stream,omitempty"`
	MaxTokens   int     `json:"max_tokens,omitempty"`
	Temperature float64 `json:"temperature,omitempty"`
}

type answer struct {
	Type          string              `json:"type"`
	Choice        string              `json:"choice"`
	Confidence    *float64            `json:"confidence"`
	Probabilities map[string]*float64 `json:"probabilities"`
}

type evaluation struct {
	Model   string            `json:"model"`
	Answers map[string]answer `json:"answers"`
	Usage   *struct {
		Input  *int `json:"input_tokens"`
		Output *int `json:"output_tokens"`
	} `json:"usage"`
}

type decision struct {
	Task, Choice, Status, Model, Profile string
	Confidence, Margin          float64
	Millis                      int64
	InputTokens, OutputTokens   int
}

type processor struct {
	ext.UnimplementedExternalProcessorServer
	client          *http.Client
	url, key string
	profile *profile
}

func bounded(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 && v <= 1 }

func decide(e evaluation, p *profile) (decision, error) {
	labels := p.Questions[p.QuestionID].Criteria
	a, ok := e.Answers[p.QuestionID]
	if !ok || a.Type != "choice" || a.Confidence == nil || !bounded(*a.Confidence) || len(a.Probabilities) != len(labels) {
		return decision{}, errors.New("invalid_choice")
	}
	if e.Model == "" || len(e.Model) > 100 || strings.ContainsAny(e.Model, "\r\n") || e.Usage == nil || e.Usage.Input == nil || e.Usage.Output == nil || *e.Usage.Input < 0 || *e.Usage.Output < 0 {
		return decision{}, errors.New("invalid_envelope")
	}
	winner, ok := a.Probabilities[a.Choice]
	if !ok || winner == nil {
		return decision{}, errors.New("unknown_choice")
	}
	sum, runnerUp := 0.0, 0.0
	for label := range labels {
		v, ok := a.Probabilities[label]
		if !ok || v == nil || !bounded(*v) {
			return decision{}, errors.New("invalid_distribution")
		}
		sum += *v
		if label != a.Choice {
			runnerUp = math.Max(runnerUp, *v)
		}
	}
	if math.Abs(sum-1) > 0.01 || *winner+1e-9 < runnerUp {
		return decision{}, errors.New("invalid_distribution")
	}
	d := decision{Task: a.Choice, Choice: a.Choice, Status: "classified", Model: e.Model, Confidence: *a.Confidence, Margin: *winner - runnerUp, InputTokens: *e.Usage.Input, OutputTokens: *e.Usage.Output}
	d.Profile = p.Hash
	if d.Confidence < *p.MinConfidence || d.Margin < *p.MinMargin {
		d.Task, d.Status = p.Fallback, "low_confidence"
	} else if d.Task == p.Fallback {
		d.Status = "fallback_choice"
	}
	return d, nil
}

func parseChat(body []byte) (chatRequest, error) {
	var c chatRequest
	if len(body) > maxBody {
		return c, errors.New("request_over_32_KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&c); err != nil {
		return c, errors.New("unsupported_chat_shape")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return c, errors.New("invalid_json")
	}
	if c.Model != "auto" || c.Stream || len(c.Messages) != 1 || c.Messages[0].Role != "user" || strings.TrimSpace(c.Messages[0].Content) == "" || c.MaxTokens < 0 || c.MaxTokens > 1024 || c.Temperature < 0 || c.Temperature > 2 {
		return c, errors.New("expected_auto_single_user_text_nonstreaming_max_1024_tokens")
	}
	return c, nil
}

func (p *processor) classify(ctx context.Context, text string) (decision, error) {
	start := time.Now()
	body, _ := json.Marshal(map[string]any{"state": text, "model": p.profile.Model, "questions": map[string]question{p.profile.QuestionID: p.profile.Questions[p.profile.QuestionID]}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.url, bytes.NewReader(body))
	if err != nil {
		return decision{}, errors.New("request_setup")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+p.key)
	resp, err := p.client.Do(req)
	if err != nil {
		return decision{}, errors.New("jev_unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return decision{}, fmt.Errorf("jev_http_%d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 65537))
	if err != nil || len(raw) > 65536 {
		return decision{}, errors.New("invalid_response_size")
	}
	var e evaluation
	if json.Unmarshal(raw, &e) != nil {
		return decision{}, errors.New("invalid_response_json")
	}
	d, err := decide(e, p.profile)
	d.Millis = time.Since(start).Milliseconds()
	return d, err
}

func mutation(d decision) *ext.HeaderMutation {
	values := []string{d.Task, d.Choice, d.Status, strconv.FormatFloat(d.Confidence, 'f', 4, 64), strconv.FormatFloat(d.Margin, 'f', 4, 64), d.Model, strconv.FormatInt(d.Millis, 10), strconv.Itoa(d.InputTokens), strconv.Itoa(d.OutputTokens), d.Profile}
	m := &ext.HeaderMutation{}
	for i, key := range ownedHeaders {
		m.SetHeaders = append(m.SetHeaders, &core.HeaderValueOption{Header: &core.HeaderValue{Key: key, RawValue: []byte(values[i])}, AppendAction: core.HeaderValueOption_OVERWRITE_IF_EXISTS_OR_ADD})
	}
	return m
}

func immediate(code types.StatusCode, message string) *ext.ProcessingResponse {
	body, _ := json.Marshal(map[string]string{"error": message})
	return &ext.ProcessingResponse{Response: &ext.ProcessingResponse_ImmediateResponse{ImmediateResponse: &ext.ImmediateResponse{Status: &types.HttpStatus{Code: code}, Body: body}}}
}

func (p *processor) Process(stream ext.ExternalProcessor_ProcessServer) error {
	var d decision
	seenHeaders, seenBody := false, false
	for {
		req, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		var reply *ext.ProcessingResponse
		switch r := req.Request.(type) {
		case *ext.ProcessingRequest_RequestHeaders:
			if seenHeaders {
				return status.Error(codes.InvalidArgument, "duplicate_headers")
			}
			seenHeaders = true
			path, method, encoding := "", "", ""
			for _, h := range r.RequestHeaders.GetHeaders().GetHeaders() {
				v := h.Value
				if len(h.RawValue) > 0 {
					v = string(h.RawValue)
				}
				switch h.Key {
				case ":path":
					path = v
				case ":method":
					method = v
				case "content-encoding":
					encoding = v
				}
			}
			if path != "/v1/chat/completions" || method != "POST" || encoding != "" || r.RequestHeaders.EndOfStream {
				return stream.Send(immediate(types.StatusCode_BadRequest, "expected_uncompressed_POST_chat_completions_with_body"))
			}
			reply = &ext.ProcessingResponse{Response: &ext.ProcessingResponse_RequestHeaders{RequestHeaders: &ext.HeadersResponse{Response: &ext.CommonResponse{HeaderMutation: &ext.HeaderMutation{RemoveHeaders: ownedHeaders}}}}}
		case *ext.ProcessingRequest_RequestBody:
			if !seenHeaders || seenBody || !r.RequestBody.EndOfStream {
				return status.Error(codes.InvalidArgument, "expected_one_buffered_body")
			}
			seenBody = true
			if len(r.RequestBody.Body) > maxBody {
				return stream.Send(immediate(types.StatusCode_PayloadTooLarge, "request_over_32_KiB"))
			}
			c, err := parseChat(r.RequestBody.Body)
			if err != nil {
				return stream.Send(immediate(types.StatusCode_BadRequest, err.Error()))
			}
			d, err = p.classify(stream.Context(), c.Messages[0].Content)
			if err != nil {
				// Never log the prompt, credentials or the provider's response body.
				slog.Warn("classification_failed", "reason", err.Error())
				return stream.Send(immediate(types.StatusCode_ServiceUnavailable, "jev_classification_unavailable"))
			}
			slog.Info("classification", "profile", d.Profile, "task", d.Task, "choice", d.Choice, "status", d.Status, "confidence", d.Confidence, "margin", d.Margin, "model", d.Model, "jev_ms", d.Millis, "input_tokens", d.InputTokens, "output_tokens", d.OutputTokens)
			// Only classification headers change. HTTPRoute selects the backend;
			// AgentgatewayBackend sets the actual model. Client model names cannot win.
			reply = &ext.ProcessingResponse{Response: &ext.ProcessingResponse_RequestBody{RequestBody: &ext.BodyResponse{Response: &ext.CommonResponse{HeaderMutation: mutation(d)}}}}
		case *ext.ProcessingRequest_ResponseHeaders:
			if !seenBody || d.Task == "" {
				return status.Error(codes.FailedPrecondition, "missing_classification")
			}
			reply = &ext.ProcessingResponse{Response: &ext.ProcessingResponse_ResponseHeaders{ResponseHeaders: &ext.HeadersResponse{Response: &ext.CommonResponse{HeaderMutation: mutation(d)}}}}
		default:
			return status.Error(codes.InvalidArgument, "unexpected_extproc_phase")
		}
		if err := stream.Send(reply); err != nil {
			return err
		}
	}
}

// A fixture proves which backend ran. It performs no inference and its usage
// values are deliberately zero. Each deployment accepts only its own model ID.
func fixture(model string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var c chatRequest
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&c) != nil || c.Model != model || c.Stream {
			http.Error(w, "fixture received the wrong model or request shape", 400)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "kb-fixture", "object": "chat.completion", "created": time.Now().Unix(), "model": model, "choices": []any{map[string]any{"index": 0, "message": map[string]string{"role": "assistant", "content": "Synthetic routing fixture. No model inference was performed."}, "finish_reason": "stop"}}, "usage": map[string]int{"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
	})
	return mux
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	fixtureModel := flag.String("fixture-model", "", "serve a synthetic OpenAI backend instead of ExtProc")
	checkProfile := flag.String("check-profile", "", "validate a profile file without credentials or network access")
	flag.Parse()
	if *checkProfile != "" {
		raw, err := os.ReadFile(*checkProfile)
		if err != nil { slog.Error("profile_read_failed", "error", err); os.Exit(1) }
		p, err := loadProfile(raw)
		if err != nil { slog.Error("profile_invalid", "error", err); os.Exit(1) }
		slog.Info("profile_valid", "profile", p.Hash, "question_id", p.QuestionID, "choices", len(p.Questions[p.QuestionID].Criteria))
		return
	}
	if *fixtureModel != "" {
		server := &http.Server{Addr: ":8080", Handler: fixture(*fixtureModel), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}
		if err := server.ListenAndServe(); err != nil {
			slog.Error("fixture_stopped", "error", err)
			os.Exit(1)
		}
		return
	}
	key, path := os.Getenv("TYPESAFE_API_KEY"), os.Getenv("JEV_PROFILE_PATH")
	if key == "" || path == "" {
		slog.Error("TYPESAFE_API_KEY and JEV_PROFILE_PATH are required")
		os.Exit(1)
	}
	raw, err := os.ReadFile(path)
	if err != nil { slog.Error("profile_read_failed", "error", err); os.Exit(1) }
	profile, err := loadProfile(raw)
	if err != nil { slog.Error("profile_invalid", "error", err); os.Exit(1) }
	listener, err := net.Listen("tcp", ":50051")
	if err != nil {
		slog.Error("listen_failed", "error", err)
		os.Exit(1)
	}
	client := &http.Client{Timeout: time.Duration(profile.RequestTimeoutMs) * time.Millisecond, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	server := grpc.NewServer(grpc.MaxRecvMsgSize(65536))
	ext.RegisterExternalProcessorServer(server, &processor{client: client, url: endpoint, key: key, profile: profile})
	slog.Info("extproc_listening", "port", 50051, "requested_model", profile.Model, "question_id", profile.QuestionID, "profile", profile.Hash)
	if err := server.Serve(listener); err != nil {
		slog.Error("server_stopped", "error", err)
		os.Exit(1)
	}
}
