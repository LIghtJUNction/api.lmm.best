package router

import (
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/controller"
	"github.com/QuantumNous/new-api/middleware"

	"github.com/gin-gonic/gin"
)

func SetRouter(router *gin.Engine) {
	SetApiRouter(router)
	SetOpenSourceBountyMCPRouter(router)
	SetDashboardRouter(router)
	SetRelayRouter(router)
	SetVideoRouter(router)
	frontendBaseUrl := os.Getenv("FRONTEND_BASE_URL")
	if common.IsMasterNode && frontendBaseUrl != "" {
		frontendBaseUrl = ""
		common.SysLog("FRONTEND_BASE_URL is ignored on master node")
	}
	if frontendBaseUrl != "" {
		frontendBaseUrl = strings.TrimSuffix(frontendBaseUrl, "/")
	}
	router.NoRoute(func(c *gin.Context) {
		c.Set(middleware.RouteTagKey, "web")
		if frontendBaseUrl == "" || isBackendPath(c.Request.RequestURI) {
			controller.RelayNotFound(c)
			return
		}
		c.Redirect(http.StatusMovedPermanently, fmt.Sprintf("%s%s", frontendBaseUrl, c.Request.RequestURI))
	})
}

func isBackendPath(requestURI string) bool {
	path := requestURI
	if queryStart := strings.IndexByte(path, '?'); queryStart >= 0 {
		path = path[:queryStart]
	}

	for _, prefix := range []string{
		"/api/",
		"/assets/",
		"/mcp/",
		"/v1/",
		"/v1beta/",
		"/pg/",
		"/mj/",
		"/suno/",
		"/kling/v1/",
		"/jimeng/",
	} {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}

	switch path {
	case "/api", "/assets", "/mcp", "/v1", "/v1beta", "/pg", "/mj", "/suno", "/kling/v1", "/jimeng", "/dashboard/billing/subscription", "/dashboard/billing/usage":
		return true
	}

	segments := strings.Split(strings.TrimPrefix(path, "/"), "/")
	return len(segments) >= 2 && segments[0] != "" && segments[1] == "mj"
}
