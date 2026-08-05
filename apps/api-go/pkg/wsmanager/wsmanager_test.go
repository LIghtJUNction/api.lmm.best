package wsmanager

import (
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func resetRegistryForTest() {
	mu.Lock()
	defer mu.Unlock()
	registry = map[int]map[uint64]*entry{}
	nextID = 0
}

func TestCloseChannelClosesOnlyMatchingRegistrationsOnce(t *testing.T) {
	resetRegistryForTest()
	var callsMu sync.Mutex
	calls := map[int]int{}
	Register(10, KindRealtime, func(reason string) {
		callsMu.Lock()
		defer callsMu.Unlock()
		assert.Equal(t, "disabled", reason)
		calls[10]++
	})
	Register(10, KindResponses, func(string) {
		callsMu.Lock()
		defer callsMu.Unlock()
		calls[10]++
	})
	Register(20, KindResponses, func(string) {
		callsMu.Lock()
		defer callsMu.Unlock()
		calls[20]++
	})

	require.Equal(t, 2, CloseChannel(10, "disabled"))
	require.Equal(t, 0, CloseChannel(10, "disabled"))
	callsMu.Lock()
	defer callsMu.Unlock()
	assert.Equal(t, 2, calls[10])
	assert.Zero(t, calls[20])
}

func TestUnregisterPreventsChannelClose(t *testing.T) {
	resetRegistryForTest()
	calls := 0
	unregister := Register(10, KindResponses, func(string) { calls++ })
	unregister()
	assert.Zero(t, CloseChannel(10, "disabled"))
	assert.Zero(t, calls)
}
