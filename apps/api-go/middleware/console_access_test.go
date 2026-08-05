package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPreActivationRouteMatrixPreservesContributorAndPaymentFlows(t *testing.T) {
	allowed := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/open-source-bounties"},
		{http.MethodGet, "/api/open-source-bounties/projects/7"},
		{http.MethodPost, "/api/open-source-bounties/projects/7/accept"},
		{http.MethodGet, "/api/user/topup/info"},
		{http.MethodPost, "/api/user/stripe/pay"},
		{http.MethodGet, "/api/user/aff"},
		{http.MethodPut, "/api/user/self"},
		{http.MethodPost, "/api/user/passkey/register/begin"},
		{http.MethodPost, "/api/token"},
		{http.MethodPost, "/api/token/"},
	}
	for _, request := range allowed {
		assert.True(t, preActivationRouteAllowed(request.method, request.path), "%s %s", request.method, request.path)
	}

	denied := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/token"},
		{http.MethodGet, "/api/models"},
		{http.MethodGet, "/api/channel"},
		{http.MethodGet, "/api/pricing"},
		{http.MethodGet, "/api/usage"},
		{http.MethodPost, "/api/subscription/admin/plans"},
		{http.MethodGet, "/api/open-source-bounties-probe"},
		{http.MethodGet, "/api/subscription-probe"},
		{http.MethodPost, "/api/open-source-bounties"},
		{http.MethodGet, "/api/open-source-bounties/mcp-token"},
		{http.MethodPut, "/api/open-source-bounties/projects/7"},
		{http.MethodPost, "/api/open-source-bounties/projects/7/publish"},
	}
	for _, request := range denied {
		assert.False(t, preActivationRouteAllowed(request.method, request.path), "%s %s", request.method, request.path)
	}
}

func TestConsoleAccessGateReturnsTheGenericNotFoundForRestrictedRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, user := range []*model.UserBase{
		{Id: 7, Role: common.RoleCommonUser, ConsoleActivatedAt: 0},
		{Id: 8, Role: common.RoleCommonUser, ConsoleActivatedAt: 10},
		{Id: 9, Role: common.RoleAdminUser, ConsoleActivatedAt: 0},
	} {
		router := gin.New()
		router.Use(func(c *gin.Context) {
			c.Set(dashboardCredentialContextKey, dashboardCredentialResult{
				user:           user,
				credentialKind: dashboardCredentialInternal,
			})
			c.Next()
		})
		router.Use(ConsoleAccessGate())
		router.GET("/api/models", func(c *gin.Context) { c.Status(http.StatusNoContent) })
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/models", nil))

		if user.ConsoleActivatedAt == 0 && user.Role < common.RoleAdminUser {
			assert.Equal(t, http.StatusNotFound, response.Code)
			assert.JSONEq(t, `{"message":"Not Found"}`, response.Body.String())
			continue
		}
		require.Equal(t, http.StatusNoContent, response.Code)
	}
}
