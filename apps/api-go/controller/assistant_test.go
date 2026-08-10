package controller

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func withAssistantSettings(t *testing.T, enabled bool, model string) {
	t.Helper()
	original := setting.GetAssistantSettings()
	setting.SetAssistantEnabled(enabled)
	require.NoError(t, setting.UpdateAssistantModel(model))
	t.Cleanup(func() {
		setting.SetAssistantEnabled(original.Enabled)
		_ = setting.UpdateAssistantModel(original.Model)
	})
}

func TestPrepareAssistantRequestOwnsModelAndPrompt(t *testing.T) {
	gin.SetMode(gin.TestMode)
	withAssistantSettings(t, true, "server-owned-model")
	engine := gin.New()
	var captured assistantOpenAIRequest
	var capturedPath string
	var capturedGroup string
	engine.POST("/api/assistant/chat", func(c *gin.Context) {
		c.Set("group", "default")
		common.SetContextKey(c, constant.ContextKeyUserGroup, "default")
		PrepareAssistantRequest(c)
	}, func(c *gin.Context) {
		capturedPath = c.Request.URL.Path
		capturedGroup = common.GetContextKeyString(c, constant.ContextKeyUsingGroup)
		require.NoError(t, common.UnmarshalBodyReusable(c, &captured))
		c.Status(http.StatusNoContent)
	})

	request := httptest.NewRequest(http.MethodPost, "/api/assistant/chat", strings.NewReader(`{"message":"How do I create a key?","model":"client-model"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, request)

	assert.Equal(t, http.StatusNoContent, response.Code)
	assert.Equal(t, "/v1/chat/completions", capturedPath)
	assert.Equal(t, "default", capturedGroup)
	assert.Equal(t, "server-owned-model", captured.Model)
	assert.False(t, captured.Stream)
	require.Len(t, captured.Messages, 2)
	assert.Equal(t, "system", captured.Messages[0].Role)
	assert.Contains(t, captured.Messages[0].Content, "Never ask for or repeat passwords")
	assert.Equal(t, "user", captured.Messages[1].Role)
	assert.Equal(t, "How do I create a key?", captured.Messages[1].Content)
}

func TestPrepareAssistantRequestRejectsDisabledAndPATRequests(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, test := range []struct {
		name        string
		enabled     bool
		accessToken bool
		wantStatus  int
		wantCode    string
	}{
		{name: "disabled", enabled: false, wantStatus: http.StatusServiceUnavailable, wantCode: "ASSISTANT_DISABLED"},
		{name: "personal access token", enabled: true, accessToken: true, wantStatus: http.StatusForbidden, wantCode: "ASSISTANT_SESSION_REQUIRED"},
	} {
		t.Run(test.name, func(t *testing.T) {
			withAssistantSettings(t, test.enabled, "assistant-model")
			engine := gin.New()
			engine.POST("/api/assistant/chat", func(c *gin.Context) {
				c.Set("use_access_token", test.accessToken)
				PrepareAssistantRequest(c)
			}, func(c *gin.Context) {
				c.Status(http.StatusNoContent)
			})
			request := httptest.NewRequest(http.MethodPost, "/api/assistant/chat", strings.NewReader(`{"message":"hello"}`))
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			engine.ServeHTTP(response, request)
			assert.Equal(t, test.wantStatus, response.Code)
			assert.Contains(t, response.Body.String(), test.wantCode)
		})
	}
}

func TestPrepareAssistantRequestRejectsOversizedMessage(t *testing.T) {
	gin.SetMode(gin.TestMode)
	withAssistantSettings(t, true, "assistant-model")
	engine := gin.New()
	engine.POST("/api/assistant/chat", PrepareAssistantRequest, func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})
	request := httptest.NewRequest(http.MethodPost, "/api/assistant/chat", strings.NewReader(`{"message":"`+strings.Repeat("问", assistantMessageMaxRunes+1)+`"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, request)
	assert.Equal(t, http.StatusRequestEntityTooLarge, response.Code)
	assert.Contains(t, response.Body.String(), "ASSISTANT_MESSAGE_TOO_LONG")
}

func TestCreateAssistantDefaultKeyRequiresConfirmation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/assistant/tools/create-key", strings.NewReader(`{"name":"my key"}`))
	c.Request.Header.Set("Content-Type", "application/json")
	CreateAssistantDefaultKey(c)
	assert.Equal(t, http.StatusUnprocessableEntity, response.Code)
	assert.Contains(t, response.Body.String(), "ASSISTANT_CONFIRMATION_REQUIRED")
}

func TestCreateAssistantDefaultKeyForL1Session(t *testing.T) {
	db := setupTokenControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.User{}))
	user := model.User{
		Username:           "assistant-key-user",
		Password:           "password",
		Role:               common.RoleCommonUser,
		Status:             common.UserStatusEnabled,
		Group:              "default",
		ConsoleActivatedAt: 1,
	}
	require.NoError(t, db.Create(&user).Error)

	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/assistant/tools/create-key", strings.NewReader(`{"confirmed":true,"name":"assistant-created"}`))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Set("id", user.Id)
	CreateAssistantDefaultKey(c)

	assert.Equal(t, http.StatusOK, response.Code)
	var payload struct {
		Success bool `json:"success"`
		Data    struct {
			ID  int    `json:"id"`
			Key string `json:"key"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(response.Body.Bytes(), &payload))
	assert.True(t, payload.Success)
	assert.Positive(t, payload.Data.ID)
	assert.True(t, strings.HasPrefix(payload.Data.Key, "sk-"))
	var token model.Token
	require.NoError(t, db.First(&token, payload.Data.ID).Error)
	assert.Equal(t, user.Id, token.UserId)
	assert.True(t, token.UnlimitedQuota)
	assert.EqualValues(t, -1, token.ExpiredTime)
}

func TestCreateAssistantDefaultKeyRejectsL0(t *testing.T) {
	db := setupTokenControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.TopUp{}))
	user := model.User{
		Username: "assistant-l0-user",
		Password: "password",
		Role:     common.RoleCommonUser,
		Status:   common.UserStatusEnabled,
		Group:    "default",
	}
	require.NoError(t, db.Create(&user).Error)

	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/assistant/tools/create-key", strings.NewReader(`{"confirmed":true}`))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Set("id", user.Id)
	CreateAssistantDefaultKey(c)
	assert.Equal(t, http.StatusForbidden, response.Code)
	assert.Contains(t, response.Body.String(), "ASSISTANT_L1_REQUIRED")
}
