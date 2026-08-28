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
	"strconv"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/service"
	"github.com/gin-gonic/gin"
)

type oauthBootstrapAPIKeyCreateRequest struct {
	Name string `json:"name"`
}

func ListOAuthBootstrapAPIKeys(c *gin.Context) {
	// pi-lens-ignore: compiler:UndeclaredImportedName
	keys, err := service.ListOAuthBootstrapAPIKeys(c.GetInt("id"))
	if err != nil {
		oauthBootstrapKeyError(c, err)
		return
	}
	oauthJSON(c, http.StatusOK, gin.H{"keys": keys})
}

func CreateOAuthBootstrapAPIKey(c *gin.Context) {
	var request oauthBootstrapAPIKeyCreateRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		oauthError(c, http.StatusBadRequest, "invalid_request", "The API key request is invalid.")
		return
	}
	// pi-lens-ignore: compiler:UndeclaredImportedName
	key, err := service.CreateOAuthBootstrapAPIKey(c.GetInt("id"), request.Name, time.Now().UTC())
	if err != nil {
		oauthBootstrapKeyError(c, err)
		return
	}
	oauthJSON(c, http.StatusCreated, key)
}

func RevealOAuthBootstrapAPIKey(c *gin.Context) {
	tokenId, err := strconv.Atoi(c.Param("id"))
	if err != nil || tokenId <= 0 {
		oauthError(c, http.StatusBadRequest, "invalid_request", "The API key identifier is invalid.")
		return
	}
	// pi-lens-ignore: compiler:UndeclaredImportedName
	key, err := service.RevealOAuthBootstrapAPIKey(c.GetInt("id"), tokenId)
	if err != nil {
		oauthBootstrapKeyError(c, err)
		return
	}
	oauthJSON(c, http.StatusOK, key)
}

func oauthBootstrapKeyError(c *gin.Context, err error) {
	switch {
	// pi-lens-ignore: compiler:UndeclaredImportedName
	case errors.Is(err, service.ErrOAuthAPIKeyName):
		oauthError(c, http.StatusBadRequest, "invalid_request", "The API key name is invalid.")
	// pi-lens-ignore: compiler:UndeclaredImportedName
	case errors.Is(err, service.ErrOAuthAPIKeyLimit):
		oauthError(c, http.StatusConflict, "key_limit_reached", "The account API key limit has been reached.")
	// pi-lens-ignore: compiler:UndeclaredImportedName
	case errors.Is(err, service.ErrOAuthAPIKeyNotFound):
		oauthError(c, http.StatusNotFound, "not_found", "The API key was not found.")
	default:
		oauthError(c, http.StatusServiceUnavailable, "temporarily_unavailable", "The API key operation is temporarily unavailable.")
	}
}
