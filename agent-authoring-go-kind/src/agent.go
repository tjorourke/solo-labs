package main

import (
	"context"
	"fmt"

	"github.com/go-logr/logr"
	"github.com/kagent-dev/kagent/go/adk/pkg/mcp"
	"github.com/kagent-dev/kagent/go/adk/pkg/models"
	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/agent/llmagent"
	"google.golang.org/adk/v2/tool"
)

// instruction is the agent's system prompt. It is the same text every part of the
// series gives its agent, so the five agents can be compared on how they are built
// rather than on what they were told.
const instruction = `You are a Kubernetes SRE. When asked about a namespace, find the pods that are
unhealthy and explain why, from evidence.

A pod is unhealthy when it is not Running, or has restarted more than three
times, or has been Pending for more than five minutes. The tool "unhealthy"
applies that gate to one pod; use it rather than judging by eye.

Method: list the pods in the namespace, pick out the unhealthy ones, then for
each one read the evidence that explains it: the pod description, the last
lines of its log, and the events for it. A container that never started has
no log, so use the events. Do not guess a cause you have not read.

Report format, plain text:
  <pod>  <state>  <one line cause>  <the one thing to check next>
one line per unhealthy pod, then one line naming the healthy pods. Keep it under
twenty lines. You have read-only tools and you do not change anything.`

// newAgent builds the one LLM agent this program runs: the Anthropic model named by
// the environment, the MCP tools kagent approved, and the local gate tool.
//
// The MCP toolsets are created by the kagent library from the approved server list. The
// agent holds no credential for the tool server and does not know what is behind the
// URL; the gateway at that URL decides which tools this identity may see.
func newAgent(ctx context.Context, cfg Config, log logr.Logger) (agent.Agent, error) {
	model, err := models.NewAnthropicModelWithLogger(&models.AnthropicConfig{Model: cfg.Model}, log)
	if err != nil {
		return nil, fmt.Errorf("model: %w", err)
	}
	gate, err := newGateTool()
	if err != nil {
		return nil, fmt.Errorf("gate tool: %w", err)
	}
	toolsets := mcp.CreateToolsets(logr.NewContext(ctx, log), cfg.MCPServers, nil, false, nil)

	return llmagent.New(llmagent.Config{
		Name:        "sre_go",
		Description: "Kubernetes SRE triage. Reports which pods in a namespace are unhealthy, and why.",
		Instruction: instruction,
		Model:       model,
		Tools:       []tool.Tool{gate},
		Toolsets:    toolsets,
	})
}
