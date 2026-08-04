package router

import (
	"github.com/QuantumNous/new-api/controller"
	"github.com/QuantumNous/new-api/middleware"
	"github.com/gin-gonic/gin"
)

func SetOpenSourceBountyMCPRouter(router *gin.Engine) {
	handler := gin.WrapH(controller.NewOpenSourceBountyMCPHandler())
	mcpRoute := router.Group("/mcp")
	mcpRoute.Use(middleware.RouteTag("mcp"))
	mcpRoute.Use(middleware.GlobalAPIRateLimit())
	mcpRoute.Any("", handler)
	mcpRoute.Any("/", handler)
}
