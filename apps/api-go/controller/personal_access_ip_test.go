package controller

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestLoopbackPeerAcceptsOnlyLoopbackAddresses(t *testing.T) {
	assert.True(t, loopbackPeer("127.0.0.1:3000"))
	assert.True(t, loopbackPeer("[::1]:3000"))
	assert.False(t, loopbackPeer("10.0.0.2:3000"))
	assert.False(t, loopbackPeer("198.51.100.2:3000"))
	assert.False(t, loopbackPeer("not-an-address"))
}
