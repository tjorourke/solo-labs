package main

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestRecordApprovalNeeded(t *testing.T) {
	before := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "delete_user"))
	recordVerdict(VerdictApprove, "users-mcp", "delete_user")
	got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "delete_user"))
	if got != before+1 {
		t.Fatalf("approval_needed after park: got %v, want %v", got, before+1)
	}
	verdicts := testutil.ToFloat64(hitlVerdicts.WithLabelValues("approve", "users-mcp", "delete_user"))
	if verdicts < 1 {
		t.Fatalf("verdicts{approve,delete_user} = %v, want at least 1", verdicts)
	}
}

func TestRecordAllowDoesNotNeedApproval(t *testing.T) {
	before := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "get_users"))
	recordVerdict(VerdictAllow, "users-mcp", "get_users")
	got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "get_users"))
	if got != before {
		t.Fatalf("allow should not increment approval_needed: got %v, want %v", got, before)
	}
}

func TestMetricsSeparateServers(t *testing.T) {
	users := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "delete_user"))
	other := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("archive-mcp", "delete_user"))
	recordVerdict(VerdictApprove, "users-mcp", "delete_user")
	recordVerdict(VerdictAllow, "archive-mcp", "delete_user")
	if got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("users-mcp", "delete_user")); got != users+1 {
		t.Fatalf("users approvals=%v", got)
	}
	if got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("archive-mcp", "delete_user")); got != other {
		t.Fatalf("other server inherited approval metric: %v", got)
	}
}
