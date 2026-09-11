package main

import (
	"fmt"

	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/tool"
	"google.golang.org/adk/v2/tool/functiontool"
)

// The gate, as a local tool. The MCP tools read the cluster; this one applies the rule
// the report is judged by, so the model does not have to hold it in its head.
//
// A local tool runs inside the agent's process. It is what a declarative agent cannot
// have, and the reason this part builds an image at all.

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
		case in.Phase != "Running" && in.Phase != "Succeeded":
			return gateResult{true, fmt.Sprintf("phase is %s, not Running", in.Phase)}, nil
		case in.Restarts > 3:
			return gateResult{true, fmt.Sprintf("%d restarts, more than three", in.Restarts)}, nil
		case in.PendingMinutes > 5:
			return gateResult{true, fmt.Sprintf("Pending for %.0f minutes", in.PendingMinutes)}, nil
		}
		return gateResult{false, "Running with three or fewer restarts"}, nil
	})
}
