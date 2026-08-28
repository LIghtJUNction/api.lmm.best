/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
package middleware

import (
	"net/http"
	"strings"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/LIghtJUNction/api.lmm.best/service"
	"github.com/gin-gonic/gin"
)

// OAuthAccessAuth validates an opaque OAuth access token and all required
// bootstrap scopes. It does not accept dashboard JWTs or API keys.
func OAuthAccessAuth(requiredScopes ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		parts := strings.Fields(c.GetHeader("Authorization"))
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
			writeOAuthAccessError(c, "invalid_token", "A Bearer access token is required.")
			return
		}
		token, err := service.ValidateOAuthAccessToken(parts[1], requiredScopes...)
		if err != nil {
			code := "invalid_token"
			if err == service.ErrOAuthInvalidScope {
				code = "insufficient_scope"
			}
			writeOAuthAccessError(c, code, "The OAuth access token is invalid or lacks scope.")
			return
		}
		user, err := model.GetUserById(token.UserId, false)
		if err != nil || user.Status != common.UserStatusEnabled || user.Role < common.RoleCommonUser {
			writeOAuthAccessError(c, "invalid_token", "The OAuth resource owner is unavailable.")
			return
		}
		c.Set("id", user.Id)
		c.Set("username", user.Username)
		c.Set("role", user.Role)
		c.Set("oauth_client_id", token.ClientId)
		c.Set("oauth_scopes", token.Scopes)
		c.Next()
	}
}

func writeOAuthAccessError(c *gin.Context, code, description string) {
	c.Header("WWW-Authenticate", `Bearer realm="api.lmm.best", error="`+code+`"`)
	c.Header("Cache-Control", "no-store")
	c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
		"error":             code,
		"error_description": description,
	})
}
