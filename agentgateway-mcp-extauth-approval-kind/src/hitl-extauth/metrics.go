package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Custom Prometheus metrics for the approval gate. Scrape GET /metrics on
// the admin HTTP port (8081). The signal that a human needs to look at the
// queue is hitl_extauth_approval_needed_total increasing, or
// hitl_extauth_pending > 0.
var (
	hitlVerdicts = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "hitl_extauth_verdicts_total",
			Help: "ConfigMap policy verdicts for MCP tools/call requests. verdict=approve means the call was parked for a reviewer.",
		},
		[]string{"verdict", "server", "tool"},
	)
	hitlApprovalNeeded = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "hitl_extauth_approval_needed_total",
			Help: "MCP tool calls parked because they matched an approve pattern and need a human decision.",
		},
		[]string{"server", "tool"},
	)
	hitlDecisions = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "hitl_extauth_decisions_total",
			Help: "How parked tool calls were resolved by a reviewer or by timeout.",
		},
		[]string{"result"},
	)
	hitlPending = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "hitl_extauth_pending",
			Help: "Number of MCP tool calls currently parked waiting for a reviewer.",
		},
	)
)

func init() {
	prometheus.MustRegister(hitlVerdicts, hitlApprovalNeeded, hitlDecisions, hitlPending)
}

func toolLabel(name string) string {
	if name == "" {
		return "none"
	}
	return name
}

func recordVerdict(v Verdict, server, tool string) {
	hitlVerdicts.WithLabelValues(v.String(), toolLabel(server), toolLabel(tool)).Inc()
	if v == VerdictApprove {
		hitlApprovalNeeded.WithLabelValues(toolLabel(server), toolLabel(tool)).Inc()
	}
}

func recordDecision(result string) {
	hitlDecisions.WithLabelValues(result).Inc()
}
