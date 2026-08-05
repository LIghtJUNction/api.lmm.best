package middleware

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestWebSocketSubprotocolAuthorization(t *testing.T) {
	tests := []struct {
		name      string
		protocols string
		wantKey   string
		wantOK    bool
	}{
		{name: "responses only", protocols: "responses"},
		{name: "realtime only", protocols: "realtime"},
		{name: "responses key", protocols: "responses, openai-insecure-api-key.sk-test", wantKey: "sk-test", wantOK: true},
		{name: "empty key", protocols: "responses, openai-insecure-api-key."},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			key, ok := apiKeyFromWebSocketSubprotocol(tt.protocols)
			assert.Equal(t, tt.wantOK, ok)
			assert.Equal(t, tt.wantKey, key)
		})
	}
}

func TestResponsesSubprotocolDoesNotReplaceAuthorization(t *testing.T) {
	header := http.Header{}
	header.Set("Authorization", "Bearer sk-original")
	header.Set("Sec-WebSocket-Protocol", "responses")
	assert.False(t, applyWebSocketSubprotocolAuthorization(header))
	assert.Equal(t, "Bearer sk-original", header.Get("Authorization"))

	header.Set("Sec-WebSocket-Protocol", "responses, openai-insecure-api-key.sk-protocol")
	assert.True(t, applyWebSocketSubprotocolAuthorization(header))
	assert.Equal(t, "Bearer sk-protocol", header.Get("Authorization"))
}
