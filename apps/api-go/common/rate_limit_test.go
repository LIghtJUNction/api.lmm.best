package common

import (
	"math"
	"testing"
	"time"
)

func TestInMemoryRateLimiterDoesNotPreallocateConfiguredMaximum(t *testing.T) {
	limiter := &InMemoryRateLimiter{}
	limiter.Init(time.Minute)

	if !limiter.Request("user", math.MaxInt, 60) {
		t.Fatal("first request was unexpectedly rejected")
	}
	if queue := limiter.store["user"]; queue == nil || len(*queue) != 1 {
		t.Fatalf("stored queue length = %v, want 1", queue)
	}
}
