package controller

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/service"
	"github.com/QuantumNous/new-api/setting"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
)

type assistantCreateKeyInput struct {
	Confirmed bool   `json:"confirmed"`
	Name      string `json:"name"`
}

type assistantHandoffInput struct {
	Confirmed bool   `json:"confirmed"`
	Message   string `json:"message"`
}

type assistantResolveHandoffInput struct {
	Note string `json:"note"`
}

func requireAssistantBrowserSession(c *gin.Context) bool {
	if c.GetBool("use_access_token") {
		writeAssistantError(c, http.StatusForbidden, "ASSISTANT_SESSION_REQUIRED", errors.New("assistant tools require a browser login session"))
		return false
	}
	return true
}

func requireAssistantConfirmation(c *gin.Context, confirmed bool) bool {
	if !confirmed {
		writeAssistantError(c, http.StatusUnprocessableEntity, "ASSISTANT_CONFIRMATION_REQUIRED", errors.New("explicit confirmation is required"))
		return false
	}
	return true
}

func getAssistantDeveloperAccess(userID int) (*model.UserBase, bool, error) {
	user, err := model.GetUserCache(userID)
	if err != nil {
		return nil, false, err
	}
	access, err := model.GetDeveloperAccessStateForUserBase(user)
	if err != nil {
		return nil, false, err
	}
	return user, access.Granted, nil
}

// CreateAssistantDefaultKey creates the same safe unlimited, non-expiring key
// offered by the regular key form. It is deliberately confirmation-gated and
// restricted to L1+ browser sessions.
func CreateAssistantDefaultKey(c *gin.Context) {
	if !requireAssistantBrowserSession(c) {
		return
	}
	var input assistantCreateKeyInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_INVALID_REQUEST", errors.New("invalid key creation request"))
		return
	}
	if !requireAssistantConfirmation(c, input.Confirmed) {
		return
	}

	userID := c.GetInt("id")
	user, granted, err := getAssistantDeveloperAccess(userID)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if !granted {
		writeAssistantError(c, http.StatusForbidden, "ASSISTANT_L1_REQUIRED", errors.New("L1 access is required to create an API key"))
		return
	}

	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = "AI assistant key"
	}
	if utf8.RuneCountInString(name) > 50 {
		writeAssistantError(c, http.StatusUnprocessableEntity, "ASSISTANT_KEY_NAME_TOO_LONG", errors.New("API key name must be at most 50 characters"))
		return
	}
	count, err := model.CountUserTokens(userID)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	maxTokens := operation_setting.GetMaxUserTokens()
	if int(count) >= maxTokens {
		writeAssistantError(c, http.StatusConflict, "ASSISTANT_KEY_LIMIT_REACHED", fmt.Errorf("API key limit reached (%d)", maxTokens))
		return
	}

	key, err := common.GenerateKey()
	if err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_KEY_GENERATE_FAILED", errors.New("failed to generate API key"))
		return
	}
	now := common.GetTimestamp()
	token := model.Token{
		UserId:             userID,
		Name:               name,
		Key:                key,
		CreatedTime:        now,
		AccessedTime:       now,
		ExpiredTime:        -1,
		UnlimitedQuota:     true,
		ModelLimitsEnabled: false,
	}
	if setting.DefaultUseAutoGroup && len(service.GetUserAutoGroup(user.Group)) > 0 {
		token.Group = "auto"
		token.CrossGroupRetry = true
	}
	if err := model.InsertTokenAndActivateConsole(&token); err != nil {
		common.ApiError(c, err)
		return
	}
	model.RecordLog(userID, model.LogTypeSystem, fmt.Sprintf("created API key %d via assistant", token.Id))
	common.ApiSuccess(c, gin.H{
		"id":           token.Id,
		"name":         token.Name,
		"key":          "sk-" + token.Key,
		"group":        token.Group,
		"expired_time": token.ExpiredTime,
	})
}

func SubmitAssistantHandoff(c *gin.Context) {
	if !requireAssistantBrowserSession(c) {
		return
	}
	var input assistantHandoffInput
	if err := c.ShouldBindJSON(&input); err != nil {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_INVALID_REQUEST", errors.New("invalid support request"))
		return
	}
	if !requireAssistantConfirmation(c, input.Confirmed) {
		return
	}
	lead, err := model.SubmitAssistantHandoff(c.GetInt("id"), input.Message)
	if err != nil {
		switch {
		case errors.Is(err, model.ErrAssistantHandoffMessageRequired), errors.Is(err, model.ErrAssistantHandoffMessageTooLong):
			writeAssistantError(c, http.StatusUnprocessableEntity, "ASSISTANT_HANDOFF_INVALID_MESSAGE", err)
		default:
			common.ApiError(c, err)
		}
		return
	}
	model.RecordLog(c.GetInt("id"), model.LogTypeSystem, fmt.Sprintf("submitted assistant support request %d", lead.Id))
	common.ApiSuccess(c, lead)
}

func GetAssistantHandoff(c *gin.Context) {
	lead, err := model.GetLatestAssistantHandoff(c.GetInt("id"))
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, lead)
}

func AdminListAssistantHandoffs(c *gin.Context) {
	leads, err := model.ListAssistantHandoffs(c.Query("status"), 100)
	if err != nil {
		if errors.Is(err, model.ErrAssistantLeadStatus) {
			writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_HANDOFF_INVALID_STATUS", err)
			return
		}
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, leads)
}

func AdminGetAssistantIntentSummary(c *gin.Context) {
	days := 30
	if raw := strings.TrimSpace(c.Query("days")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 365 {
			writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_INTENT_DAYS_INVALID", errors.New("days must be between 1 and 365"))
			return
		}
		days = parsed
	}
	since := time.Now().Add(-time.Duration(days) * 24 * time.Hour).Unix()
	summary, err := model.ListAssistantIntentSummary(since)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, summary)
}

func AdminResolveAssistantHandoff(c *gin.Context) {
	leadID, err := strconv.Atoi(c.Param("id"))
	if err != nil || leadID <= 0 {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_HANDOFF_INVALID_ID", errors.New("invalid support request id"))
		return
	}
	var input assistantResolveHandoffInput
	if c.Request.ContentLength != 0 {
		if err := c.ShouldBindJSON(&input); err != nil {
			writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_INVALID_REQUEST", errors.New("invalid support resolution"))
			return
		}
	}
	lead, err := model.ResolveAssistantHandoff(c.GetInt("id"), leadID, input.Note)
	if err != nil {
		switch {
		case errors.Is(err, model.ErrAssistantLeadNotFound):
			writeAssistantError(c, http.StatusNotFound, "ASSISTANT_HANDOFF_NOT_FOUND", err)
		case errors.Is(err, model.ErrAssistantLeadAlreadyResolved):
			writeAssistantError(c, http.StatusConflict, "ASSISTANT_HANDOFF_ALREADY_RESOLVED", err)
		case errors.Is(err, model.ErrAssistantAdminNoteTooLong):
			writeAssistantError(c, http.StatusUnprocessableEntity, "ASSISTANT_HANDOFF_NOTE_TOO_LONG", err)
		default:
			common.ApiError(c, err)
		}
		return
	}
	model.RecordLog(c.GetInt("id"), model.LogTypeSystem, fmt.Sprintf("resolved assistant support request %d", lead.Id))
	common.ApiSuccess(c, lead)
}
