package controller

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-gonic/gin"
)

func assistantHistoryVisibilityError(c *gin.Context, err error) bool {
	if errors.Is(err, model.ErrAssistantConversationNotFound) || errors.Is(err, model.ErrAssistantHistoryForbidden) {
		// Do not reveal whether another account has a conversation.  This applies
		// to both a guessed conversation id and a user_id query parameter.
		writeAssistantError(c, http.StatusNotFound, "ASSISTANT_HISTORY_NOT_FOUND", errors.New("assistant conversation was not found"))
		return true
	}
	return false
}

// ListAssistantConversations is intentionally authenticated as a normal user
// route.  The model layer decides whether the requested owner is the viewer or
// a strictly lower-level account; query parameters are never authority.
func ListAssistantConversations(c *gin.Context) {
	viewerUserID := c.GetInt("id")
	ownerUserID := viewerUserID
	if rawOwnerID := strings.TrimSpace(c.Query("user_id")); rawOwnerID != "" {
		parsed, err := strconv.Atoi(rawOwnerID)
		if err != nil || parsed <= 0 {
			writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_HISTORY_INVALID_USER", errors.New("user_id must be a positive integer"))
			return
		}
		ownerUserID = parsed
	}
	limit, err := strconv.Atoi(strings.TrimSpace(c.DefaultQuery("limit", "30")))
	if err != nil || limit < 1 {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_HISTORY_INVALID_LIMIT", errors.New("limit must be a positive integer"))
		return
	}
	conversations, err := model.ListAssistantConversations(viewerUserID, ownerUserID, limit)
	if assistantHistoryVisibilityError(c, err) {
		return
	}
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, gin.H{
		"conversations":  conversations,
		"privacy_notice": model.AssistantHistoryPrivacyNotice,
	})
}

func GetAssistantConversationHistory(c *gin.Context) {
	conversationID, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || conversationID <= 0 {
		writeAssistantError(c, http.StatusNotFound, "ASSISTANT_HISTORY_NOT_FOUND", errors.New("assistant conversation was not found"))
		return
	}
	limit, err := strconv.Atoi(strings.TrimSpace(c.DefaultQuery("limit", "100")))
	if err != nil || limit < 1 {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_HISTORY_INVALID_LIMIT", errors.New("limit must be a positive integer"))
		return
	}
	conversation, messages, err := model.GetAssistantConversationHistory(c.GetInt("id"), conversationID, limit)
	if assistantHistoryVisibilityError(c, err) {
		return
	}
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, gin.H{
		"conversation":   conversation,
		"messages":       messages,
		"privacy_notice": model.AssistantHistoryPrivacyNotice,
	})
}

// RevealAssistantSecureCard returns the encrypted value once, after normal
// dashboard authentication plus the existing browser-session requirement.
// Elevated users may inspect a lower-level transcript, but never reveal that
// user's card value.
func RevealAssistantSecureCard(c *gin.Context) {
	if !requireAssistantBrowserSession(c) {
		return
	}
	payload, card, err := model.RevealAssistantSecureCard(c.GetInt("id"), c.Param("id"))
	if errors.Is(err, model.ErrAssistantSecureCardNotFound) {
		writeAssistantError(c, http.StatusNotFound, "ASSISTANT_SECURE_CARD_NOT_FOUND", errors.New("secure card was not found"))
		return
	}
	if errors.Is(err, model.ErrAssistantSecureCardConsumed) {
		writeAssistantError(c, http.StatusGone, "ASSISTANT_SECURE_CARD_CONSUMED", errors.New("secure card has already been revealed"))
		return
	}
	if errors.Is(err, model.ErrAssistantSecureCardExpired) {
		writeAssistantError(c, http.StatusGone, "ASSISTANT_SECURE_CARD_EXPIRED", errors.New("secure card has expired"))
		return
	}
	if err != nil {
		common.ApiError(c, err)
		return
	}
	decoded, err := model.AssistantSecureCardPayload(payload)
	if err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_SECURE_CARD_INVALID", errors.New("secure card could not be decoded"))
		return
	}
	common.ApiSuccess(c, gin.H{
		"card":           card,
		"payload":        decoded,
		"privacy_notice": model.AssistantHistoryPrivacyNotice,
	})
}
