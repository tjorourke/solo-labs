package main

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestRecordApprovalNeeded(t *testing.T) {
	before := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("delete_user"))
	recordVerdict(VerdictApprove, "delete_user")
	got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("delete_user"))
	if got != before+1 {
		t.Fatalf("approval_needed after park: got %v, want %v", got, before+1)
	}
	verdicts := testutil.ToFloat64(hitlVerdicts.WithLabelValues("approve", "delete_user"))
	if verdicts < 1 {
		t.Fatalf("verdicts{approve,delete_user} = %v, want at least 1", verdicts)
	}
}

func TestRecordAllowDoesNotNeedApproval(t *testing.T) {
	before := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("get_users"))
	recordVerdict(VerdictAllow, "get_users")
	got := testutil.ToFloat64(hitlApprovalNeeded.WithLabelValues("get_users"))
	if got != before {
		t.Fatalf("allow should not increment approval_needed: got %v, want %v", got, before)
	}
}
