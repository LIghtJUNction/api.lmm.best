package controller

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/middleware"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/relaykit/types"
	"github.com/QuantumNous/new-api/service"
	"github.com/QuantumNous/new-api/setting"
	"github.com/gin-gonic/gin"
)

const assistantMessageMaxRunes = 4000

const assistantSystemPrompt = `You are the built-in customer assistant for LMM, an AI API service.
Answer in the user's language and be concise, accurate, and practical.
You may explain onboarding review, plans, pricing, discounts, API keys, Base URL and model IDs, cost calculations, open-source bounties and tips, and setup for Claude Code, CC Switch, ChatGPT-compatible clients, Windows, Linux, and macOS.
Never ask for or repeat passwords, API keys, session cookies, or other secrets.
Never claim that you created a key, changed an account, contacted an administrator, purchased a plan, or completed any other action. Explain the confirmation step or direct the user to the relevant page instead.
When information depends on live account state or current pricing, say that the user should confirm it in the console rather than inventing a value.`

type assistantChatInput struct {
	Message string `json:"message"`
}

type assistantOpenAIMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type assistantOpenAIRequest struct {
	Model       string                   `json:"model"`
	Messages    []assistantOpenAIMessage `json:"messages"`
	Stream      bool                     `json:"stream"`
	Temperature float64                  `json:"temperature"`
	MaxTokens   int                      `json:"max_tokens"`
}

func writeAssistantError(c *gin.Context, status int, code string, err error) {
	c.AbortWithStatusJSON(status, gin.H{
		"success": false,
		"code":    code,
		"message": err.Error(),
	})
}

// PrepareAssistantRequest validates the narrow browser contract, then replaces
// it with a server-owned OpenAI request before channel selection. This keeps
// the configured model, system prompt, and billing boundary outside user
// control.
func PrepareAssistantRequest(c *gin.Context) {
	settings := setting.GetAssistantSettings()
	if !settings.Enabled {
		writeAssistantError(c, http.StatusServiceUnavailable, "ASSISTANT_DISABLED", errors.New("AI assistant is disabled"))
		return
	}
	if c.GetBool("use_access_token") {
		writeAssistantError(c, http.StatusForbidden, "ASSISTANT_SESSION_REQUIRED", errors.New("AI assistant requires a browser login session"))
		return
	}

	var input assistantChatInput
	if err := common.UnmarshalBodyReusable(c, &input); err != nil {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_INVALID_REQUEST", errors.New("invalid assistant request"))
		return
	}
	input.Message = strings.TrimSpace(input.Message)
	if input.Message == "" {
		writeAssistantError(c, http.StatusBadRequest, "ASSISTANT_MESSAGE_REQUIRED", errors.New("assistant message is required"))
		return
	}
	if utf8.RuneCountInString(input.Message) > assistantMessageMaxRunes {
		writeAssistantError(c, http.StatusRequestEntityTooLarge, "ASSISTANT_MESSAGE_TOO_LONG", fmt.Errorf("assistant message must be at most %d characters", assistantMessageMaxRunes))
		return
	}

	request := assistantOpenAIRequest{
		Model: settings.Model,
		Messages: []assistantOpenAIMessage{
			{Role: "system", Content: assistantSystemPrompt},
			{Role: "user", Content: input.Message},
		},
		Stream:      false,
		Temperature: 0.2,
		MaxTokens:   900,
	}
	payload, err := common.Marshal(request)
	if err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_REQUEST_BUILD_FAILED", errors.New("failed to build assistant request"))
		return
	}

	common.CleanupBodyStorage(c)
	storage, err := common.CreateBodyStorage(payload)
	if err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_REQUEST_BUILD_FAILED", errors.New("failed to store assistant request"))
		return
	}
	c.Set(common.KeyBodyStorage, storage)
	c.Set("assistant_request", true)
	c.Request.Body = io.NopCloser(storage)
	c.Request.ContentLength = int64(len(payload))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Request.URL.Path = "/v1/chat/completions"
	c.Request.URL.RawPath = ""
	c.Request.RequestURI = "/v1/chat/completions"

	usingGroup := common.GetContextKeyString(c, constant.ContextKeyUserGroup)
	if usingGroup == "" {
		usingGroup = c.GetString("group")
	}
	common.SetContextKey(c, constant.ContextKeyUsingGroup, usingGroup)
	c.Next()
}

func AssistantChat(c *gin.Context) {
	userId := c.GetInt("id")
	userCache, err := model.GetUserCache(userId)
	if err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_USER_LOOKUP_FAILED", errors.New("failed to load assistant account"))
		return
	}
	userCache.WriteContext(c)
	usingGroup := common.GetContextKeyString(c, constant.ContextKeyUsingGroup)
	tempToken := &model.Token{
		UserId:         userId,
		Name:           "system-assistant",
		Group:          usingGroup,
		UnlimitedQuota: true,
	}
	if err := middleware.SetupContextForToken(c, tempToken); err != nil {
		writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_CONTEXT_FAILED", errors.New("failed to prepare assistant context"))
		return
	}
	Relay(c, types.RelayFormatOpenAI)
}

func GetAssistantStatus(c *gin.Context) {
	settings := setting.GetAssistantSettings()
	credit, err := service.GetAssistantCreditStatus(c.GetInt("id"), time.Now())
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, gin.H{
		"enabled": settings.Enabled,
		"model":   settings.Model,
		"credit":  credit,
	})
}
