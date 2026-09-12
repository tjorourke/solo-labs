package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/kagent-dev/kagent/go/api/adk"
)

// Config holds the identity, controller URL, model and MCP servers from the pod environment.
type Config struct {
	Name          string // KAGENT_NAME
	Namespace     string // KAGENT_NAMESPACE
	ControllerURL string // KAGENT_URL, empty when running outside kagent
	Model         string // MODEL_NAME
	MCPServers    []adk.HttpMcpServerConfig
}

// approvedServer is one entry of MCP_SERVERS_CONFIG as kagent and AgentRegistry write it.
type approvedServer struct {
	Name string `json:"name"`
	Type string `json:"type"`
	URL  string `json:"url"`
}

// configFromEnv reads the environment. It fails on a missing model rather than picking
// one, so the agent runs the model the Agent resource says and no other.
func configFromEnv() (Config, error) {
	cfg := Config{
		Name:          os.Getenv("KAGENT_NAME"),
		Namespace:     os.Getenv("KAGENT_NAMESPACE"),
		ControllerURL: os.Getenv("KAGENT_URL"),
		Model:         os.Getenv("MODEL_NAME"),
	}
	if cfg.Model == "" {
		return cfg, fmt.Errorf("MODEL_NAME is not set")
	}
	raw := os.Getenv("MCP_SERVERS_CONFIG")
	if raw == "" {
		return cfg, nil
	}
	var servers []approvedServer
	if err := json.Unmarshal([]byte(raw), &servers); err != nil {
		return cfg, fmt.Errorf("MCP_SERVERS_CONFIG is not a JSON list: %w", err)
	}
	for _, s := range servers {
		// Only remote servers reach a BYO agent; kagent has no other type to inject.
		if s.Type != "remote" {
			continue
		}
		cfg.MCPServers = append(cfg.MCPServers, adk.HttpMcpServerConfig{
			Params: adk.StreamableHTTPConnectionParams{Url: s.URL},
		})
	}
	return cfg, nil
}

// appName is the identity kagent files sessions and tasks under: the namespace and
// name joined by __NS__, with dashes turned into underscores, the same derivation the
// library and the Python runtime use.
func (c Config) appName() string {
	if c.Namespace == "" || c.Name == "" {
		return "sre-go"
	}
	return strings.ReplaceAll(c.Namespace, "-", "_") + "__NS__" + strings.ReplaceAll(c.Name, "-", "_")
}
