package main

import (
	"fmt"

	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/tool"
	"google.golang.org/adk/v2/tool/functiontool"
)

// This local tool evaluates pod health using values collected by the MCP tools.

// gateArgs is what the model passes in: the pod's phase and restart count, and how long
// it has been Pending. JSON tags become the tool's input schema.
type gateArgs struct {
	Phase          string  `json:"phase" jsonschema:"the pod phase, e.g. Running, Pending, Failed"`
	Restarts       int     `json:"restarts" jsonschema:"total container restarts"`
	PendingMinutes float64 `json:"pending_minutes" jsonschema:"minutes the pod has been Pending, 0 if it is not"`
}

// gateResult is the verdict and the clause that produced it.
type gateResult struct {
	Unhealthy bool   `json:"unhealthy"`
	Reason    string `json:"reason"`
}

// newGateTool builds the tool from a plain function. The library infers the schema from
// the argument and result types.
func newGateTool() (tool.Tool, error) {
	return functiontool.New(functiontool.Config{
		Name: "unhealthy",
		Description: "Apply the health gate to one pod: unhealthy when it is not Running, " +
			"or has restarted more than three times, or has been Pending for more than five minutes.",
	}, func(_ agent.Context, in gateArgs) (gateResult, error) {
		switch {
		case in.Phase == "Pending" && in.PendingMinutes > 5:
			return gateResult{true, fmt.Sprintf("Pending for %.0f minutes, more than five", in.PendingMinutes)}, nil
		case in.Phase == "Pending":
			return gateResult{false, fmt.Sprintf("Pending for %.0f minutes, within the five minute allowance", in.PendingMinutes)}, nil
		case in.Phase != "Running":
			return gateResult{true, fmt.Sprintf("phase is %s, not Running", in.Phase)}, nil
		case in.Restarts > 3:
			return gateResult{true, fmt.Sprintf("%d restarts, more than three", in.Restarts)}, nil
		}
		return gateResult{false, "Running with three or fewer restarts"}, nil
	})
}
