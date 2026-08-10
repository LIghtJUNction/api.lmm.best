package types

import (
	"errors"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestToOpenAIErrorUsesActionableFallbackForEmptyUpstreamMessage(t *testing.T) {
	err := InitOpenAIError(ErrorCodeDoRequestFailed, http.StatusBadGateway)

	openAIError := err.ToOpenAIError()

	require.Equal(t, "upstream request failed (HTTP 502); please retry.", openAIError.Message)
	require.Equal(t, ErrorCodeDoRequestFailed, openAIError.Code)
}

func TestToOpenAIErrorPreservesUnderlyingMessage(t *testing.T) {
	err := NewOpenAIError(errors.New("upstream returned a useful message"), ErrorCodeBadResponse, http.StatusBadGateway)

	openAIError := err.ToOpenAIError()

	require.Equal(t, "upstream returned a useful message", openAIError.Message)
}

func TestToOpenAIErrorMasksUsefulFallbackMessage(t *testing.T) {
	err := InitOpenAIError(ErrorCodeDoRequestFailed, http.StatusBadGateway)
	err.Err = errors.New("upstream rejected api_key:secret-value")

	openAIError := err.ToOpenAIError()

	require.Equal(t, "upstream rejected api_key:***", openAIError.Message)
}
