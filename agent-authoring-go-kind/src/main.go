// sre-go is a kagent BYO agent written in Go on kagent's Go ADK.
//
// The program wires four things and then hands over to the library:
//
//  1. a Config read from the environment kagent injects,
//  2. an LLM agent (model, MCP tools, one local tool),
//  3. kagent's executor, which runs a turn and emits the A2A events the UI draws,
//  4. the app, which serves the agent card and JSON-RPC and persists sessions and
//     tasks to the controller at KAGENT_URL, authenticating with the pod's projected
//     token.
//
// Nothing in this file speaks A2A or HTTP directly. That is the point of the library.
package main

import (
	"context"
	"net/http"
	"os"
	"time"

	a2atype "github.com/a2aproject/a2a-go/a2a"
	"github.com/go-logr/logr"
	"github.com/go-logr/zapr"
	"github.com/kagent-dev/kagent/go/adk/pkg/a2a"
	"github.com/kagent-dev/kagent/go/adk/pkg/app"
	"github.com/kagent-dev/kagent/go/adk/pkg/auth"
	"github.com/kagent-dev/kagent/go/adk/pkg/session"
	"github.com/kagent-dev/kagent/go/adk/pkg/telemetry"
	"go.uber.org/zap"
	"google.golang.org/adk/v2/runner"
)

func main() {
	zapLogger, _ := zap.NewProduction()
	defer func() { _ = zapLogger.Sync() }()
	log := zapr.NewLogger(zapLogger)

	if err := run(log); err != nil {
		log.Error(err, "sre-go exited")
		os.Exit(1)
	}
}

func run(log logr.Logger) error {
	cfg, err := configFromEnv()
	if err != nil {
		return err
	}
	appName := cfg.appName()
	ctx := context.Background()

	// The library's tracing reads the OTEL_* variables kagent injects. With none set it
	// stays off, and says so.
	shutdownTelemetry, enabled, err := telemetry.Init(ctx, cfg.Name, cfg.Namespace)
	if err != nil {
		log.Error(err, "telemetry not initialised; continuing without it")
	} else if enabled {
		defer func() {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = shutdownTelemetry(shutdownCtx)
		}()
	}

	// One HTTP client, authenticated with the projected service-account token, shared by
	// the session service and the task store so there is one token refresher, not two.
	// Outside kagent (no KAGENT_URL) both stay in memory and nothing is persisted.
	var httpClient *http.Client
	if cfg.ControllerURL != "" {
		tokens := auth.NewKAgentTokenService(appName)
		if err := tokens.Start(ctx); err != nil {
			return err
		}
		defer tokens.Stop()
		httpClient = auth.NewHTTPClientWithToken(tokens)
	}
	sessions, err := session.NewService("", cfg.ControllerURL, httpClient)
	if err != nil {
		return err
	}

	sre, err := newAgent(ctx, cfg, log)
	if err != nil {
		return err
	}

	// kagent's executor runs the ADK runner for each A2A request and converts the
	// runner's events into the status-update and artifact-update frames the UI reads.
	executor := a2a.NewKAgentExecutor(a2a.KAgentExecutorConfig{
		RunnerConfig:   runner.Config{AppName: appName, Agent: sre, SessionService: sessions},
		SessionService: sessions,
		Stream:         true,
		AppName:        appName,
		Logger:         log,
	})

	// The card is kagent's readiness probe, served at /.well-known/agent-card.json. It is
	// written here in full; the library would otherwise derive skills from the agent.
	card := a2atype.AgentCard{
		Name:            cfg.Name,
		Description:     "Kubernetes SRE triage. Reports which pods in a namespace are unhealthy, and why.",
		Version:         "1.0.0",
		ProtocolVersion: "0.3.0",
		URL:             "http://localhost:8080",
		Capabilities: a2atype.AgentCapabilities{
			Streaming:              true,
			StateTransitionHistory: true,
		},
		DefaultInputModes:  []string{"text"},
		DefaultOutputModes: []string{"text"},
		Skills: []a2atype.AgentSkill{{
			ID:          "triage-namespace",
			Name:        "Triage a namespace",
			Description: "Report which pods in a namespace are unhealthy and why",
			Tags:        []string{"kubernetes", "sre", "triage"},
			Examples:    []string{"Which pods in sre-lab are unhealthy, and why?"},
		}},
	}

	kagentApp, err := app.New(app.AppConfig{
		AgentCard:  card,
		KAgentURL:  cfg.ControllerURL,
		AppName:    appName,
		Logger:     log,
		HTTPClient: httpClient,
	}, executor)
	if err != nil {
		return err
	}
	log.Info("sre-go starting", "app", appName, "model", cfg.Model, "mcpServers", len(cfg.MCPServers), "controller", cfg.ControllerURL)
	return kagentApp.Run()
}
