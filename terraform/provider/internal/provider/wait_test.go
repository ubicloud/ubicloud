package provider

import (
	"context"
	"strings"
	"testing"
	"time"
)

// settle reads at once and again while the lifecycle value is pending. The
// waits between reads double from the poll interval up to six times it:
// 10+20+40+60+60+60+60+60 ms here, where without the cap they would come to
// 2550 ms. A loaded machine can only make the waits longer, so the upper
// bound is the uncapped sum, far above the capped one.
func TestSettleBacksOff(t *testing.T) {
	var replies []reply
	for range 8 {
		replies = append(replies, reply{200, creating, ""})
	}
	h := newHarness(t, gadget(), map[string][]reply{"GET " + gadgetPath: append(replies, reply{200, running, ""})})
	h.r.c.poll = 10 * time.Millisecond
	start := time.Now()
	body, err := h.r.settle(context.Background(), gadgetPath)
	elapsed := time.Since(start)
	if err != nil || body["state"] != "running" {
		t.Fatalf("settle = %v, %v", body, err)
	}
	if n := strings.Count(h.api.requests(), "GET"); n != 9 {
		t.Errorf("%d reads, want 9", n)
	}
	if elapsed < 370*time.Millisecond || elapsed >= 2550*time.Millisecond {
		t.Errorf("settled in %v, want the 370 ms of a backoff capped at six intervals", elapsed)
	}
}
