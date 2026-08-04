package router

import (
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestApiRouterRegistersPublicLivenessRoute(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	SetApiRouter(engine)

	for _, route := range engine.Routes() {
		if route.Method == "GET" && route.Path == "/api/livez" {
			require.Equal(t, "github.com/QuantumNous/new-api/controller.GetLiveness", route.Handler)
			return
		}
	}
	t.Fatal("GET /api/livez was not registered")
}
