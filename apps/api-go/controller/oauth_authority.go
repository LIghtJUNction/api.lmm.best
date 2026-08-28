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
package controller

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/LIghtJUNction/api.lmm.best/service"
	"github.com/gin-gonic/gin"
)

type oauthAuthorizationDecisionRequest struct {
	Approve bool `json:"approve"`
}

type oauthDeviceDecisionRequest struct {
	UserCode string `json:"user_code" binding:"required"`
	Approve  bool   `json:"approve"`
}

type oauthErrorResponse struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description,omitempty"`
}

func GetOAuthAuthorizationServerMetadata(c *gin.Context) {
	metadata, err := service.OAuthMetadata()
	if err != nil {
		oauthError(c, http.StatusServiceUnavailable, "temporarily_unavailable", "OAuth issuer is not configured.")
		return
	}
	c.Header("Cache-Control", "public, max-age=300")
	c.JSON(http.StatusOK, metadata)
}

func BeginOAuthAuthorization(c *gin.Context) {
	requestToken, consentURL, err := service.CreateOAuthAuthorizationRequest(service.OAuthAuthorizationInput{
		ClientId:            c.Query("client_id"),
		RedirectURI:         c.Query("redirect_uri"),
		ResponseType:        c.Query("response_type"),
		Scope:               c.Query("scope"),
		State:               c.Query("state"),
		CodeChallenge:       c.Query("code_challenge"),
		CodeChallengeMethod: c.Query("code_challenge_method"),
	}, time.Now().UTC())
	if err != nil {
		writeOAuthServiceError(c, err)
		return
	}
	if requestToken == "" {
		oauthError(c, http.StatusServiceUnavailable, "temporarily_unavailable", "Authorization could not be started.")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Redirect(http.StatusFound, consentURL)
}

func CreateOAuthDeviceCode(c *gin.Context) {
	if !requireOAuthForm(c) {
		return
	}
	response, err := service.CreateOAuthDeviceAuthorization(
		c.PostForm("client_id"), c.PostForm("scope"), time.Now().UTC(),
	)
	if err != nil {
		writeOAuthServiceError(c, err)
		return
	}
	oauthJSON(c, http.StatusOK, response)
}

func ExchangeOAuthToken(c *gin.Context) {
	if !requireOAuthForm(c) {
		return
	}
	var response *service.OAuthTokenResponse
	var err error
	switch c.PostForm("grant_type") {
	case "authorization_code":
		response, err = service.ExchangeOAuthAuthorizationCode(
			c.PostForm("code"), c.PostForm("client_id"), c.PostForm("redirect_uri"),
			c.PostForm("code_verifier"), time.Now().UTC(),
		)
	case "urn:ietf:params:oauth:grant-type:device_code":
		response, err = service.ExchangeOAuthDeviceCode(
			c.PostForm("device_code"), c.PostForm("client_id"), time.Now().UTC(),
		)
	case "refresh_token":
		response, err = service.ExchangeOAuthRefreshToken(
			c.PostForm("refresh_token"), c.PostForm("client_id"), time.Now().UTC(),
		)
	default:
		err = service.ErrOAuthUnsupportedGrant
	}
	if err != nil {
		writeOAuthServiceError(c, err)
		return
	}
	oauthJSON(c, http.StatusOK, response)
}

func RevokeOAuthToken(c *gin.Context) {
	if !requireOAuthForm(c) {
		return
	}
	if err := service.RevokeOAuthGrantToken(c.PostForm("token"), time.Now().UTC()); err != nil {
		oauthError(c, http.StatusServiceUnavailable, "temporarily_unavailable", "Token revocation is temporarily unavailable.")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusOK)
}

func GetOAuthAuthorizationRequest(c *gin.Context) {
	preview, err := service.GetOAuthAuthorizationPreview(c.Param("request"))
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, preview)
}

func DecideOAuthAuthorization(c *gin.Context) {
	var request oauthAuthorizationDecisionRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		common.ApiError(c, err)
		return
	}
	decision, err := service.DecideOAuthAuthorization(
		c.Param("request"), c.GetInt("id"), request.Approve, time.Now().UTC(),
	)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, decision)
}

func DecideOAuthDeviceAuthorization(c *gin.Context) {
	var request oauthDeviceDecisionRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		common.ApiError(c, err)
		return
	}
	if err := service.DecideOAuthDeviceAuthorization(
		request.UserCode, c.GetInt("id"), request.Approve, time.Now().UTC(),
	); err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, gin.H{"approved": request.Approve})
}

func requireOAuthForm(c *gin.Context) bool {
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(c.GetHeader("Content-Type"), ";")[0]))
	if contentType != "application/x-www-form-urlencoded" {
		oauthError(c, http.StatusBadRequest, "invalid_request", "Content-Type must be application/x-www-form-urlencoded.")
		return false
	}
	return true
}

func writeOAuthServiceError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, service.ErrOAuthInvalidClient):
		oauthError(c, http.StatusBadRequest, "invalid_client", "The public client is not registered.")
	case errors.Is(err, service.ErrOAuthInvalidScope):
		oauthError(c, http.StatusBadRequest, "invalid_scope", "The requested scope is not allowed.")
	case errors.Is(err, service.ErrOAuthInvalidRedirectURI), errors.Is(err, service.ErrOAuthInvalidPKCE), errors.Is(err, service.ErrOAuthInvalidRequest):
		oauthError(c, http.StatusBadRequest, "invalid_request", "The authorization request is invalid.")
	case errors.Is(err, service.ErrOAuthUnsupportedGrant):
		oauthError(c, http.StatusBadRequest, "unsupported_grant_type", "The grant type is not supported.")
	case errors.Is(err, model.ErrOAuthAuthorizationPending):
		oauthError(c, http.StatusBadRequest, "authorization_pending", "Authorization is still pending.")
	case errors.Is(err, model.ErrOAuthSlowDown):
		oauthError(c, http.StatusBadRequest, "slow_down", "Polling is too frequent.")
	case errors.Is(err, model.ErrOAuthAccessDenied), errors.Is(err, service.ErrOAuthAccessDenied):
		oauthError(c, http.StatusBadRequest, "access_denied", "The user denied authorization.")
	case errors.Is(err, model.ErrOAuthExpiredToken):
		oauthError(c, http.StatusBadRequest, "expired_token", "The device code has expired.")
	default:
		oauthError(c, http.StatusBadRequest, "invalid_grant", "The grant is invalid or expired.")
	}
}

func oauthJSON(c *gin.Context, status int, value any) {
	c.Header("Cache-Control", "no-store")
	c.Header("Pragma", "no-cache")
	c.JSON(status, value)
}

func oauthError(c *gin.Context, status int, code, description string) {
	oauthJSON(c, status, oauthErrorResponse{Error: code, ErrorDescription: description})
}
