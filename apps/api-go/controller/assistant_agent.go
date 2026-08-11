package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/relaykit/types"
	"github.com/QuantumNous/new-api/setting"
	"github.com/QuantumNous/new-api/setting/system_setting"
	"github.com/gin-gonic/gin"
)

const (
	assistantToolArgumentsMaxBytes = 16 * 1024
	assistantToolCallsPerTurn      = 4
	assistantAgentDefaultTimeout   = 45 * time.Second
)

type assistantOpenAIToolDefinition struct {
	Type     string                      `json:"type"`
	Function assistantOpenAIToolFunction `json:"function"`
}

type assistantOpenAIToolFunction struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

type assistantOpenAIToolCall struct {
	ID       string                          `json:"id"`
	Type     string                          `json:"type"`
	Function assistantOpenAIToolCallFunction `json:"function"`
}

type assistantOpenAIToolCallFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type assistantOpenAIResponse struct {
	Choices []assistantOpenAIResponseChoice `json:"choices"`
}

type assistantOpenAIResponseChoice struct {
	Message assistantOpenAIResponseMessage `json:"message"`
}

type assistantOpenAIResponseMessage struct {
	Role      string                    `json:"role"`
	Content   json.RawMessage           `json:"content"`
	ToolCalls []assistantOpenAIToolCall `json:"tool_calls"`
}

func assistantToolDefinitions() []assistantOpenAIToolDefinition {
	return []assistantOpenAIToolDefinition{
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_service_facts",
				Description: "Return the current public connection facts for this LMM console. Use this before explaining Base URL, the default model ID, or where to manage private API keys.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "calculate_cost",
				Description: "Calculate an estimated USD cost from token counts and supplied per-million-token prices. Never invent prices; ask for missing prices when needed.",
				Parameters: objectSchema(map[string]any{
					"input_tokens":           map[string]any{"type": "number", "minimum": 0},
					"output_tokens":          map[string]any{"type": "number", "minimum": 0},
					"input_usd_per_million":  map[string]any{"type": "number", "minimum": 0},
					"output_usd_per_million": map[string]any{"type": "number", "minimum": 0},
					"group_ratio":            map[string]any{"type": "number", "minimum": 0},
				}, []string{"input_tokens", "output_tokens", "input_usd_per_million", "output_usd_per_million"}),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_account_access",
				Description: "Read the signed-in user's non-secret access state, such as trust level and whether developer features are unlocked.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_setup_guide",
				Description: "Return a concise platform-specific setup checklist for Claude Code, CC Switch, or ChatGPT-compatible clients.",
				Parameters: objectSchema(map[string]any{
					"platform": map[string]any{"type": "string", "enum": []string{"windows", "linux", "macos"}},
					"topic":    map[string]any{"type": "string", "enum": []string{"claude-code", "cc-switch", "chatgpt-client"}},
				}, []string{"platform", "topic"}),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "request_create_key",
				Description: "Prepare the instructions for creating an API key. This is a write action and must remain confirmation-gated; never claim a key was created from this tool.",
				Parameters: objectSchema(map[string]any{
					"name": map[string]any{"type": "string", "maxLength": 50},
				}, nil),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "request_human_support",
				Description: "Prepare a handoff to an administrator. This is a write action and requires an explicit confirmation in the UI.",
				Parameters: objectSchema(map[string]any{
					"message": map[string]any{"type": "string", "maxLength": 4000},
				}, []string{"message"}),
			},
		},
	}
}

func emptyObjectSchema() map[string]any {
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{},
		"additionalProperties": false,
	}
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	schema := map[string]any{
		"type":                 "object",
		"properties":           properties,
		"additionalProperties": false,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func setAssistantRelayRequest(c *gin.Context, request assistantOpenAIRequest) error {
	payload, err := common.Marshal(request)
	if err != nil {
		return err
	}

	common.CleanupBodyStorage(c)
	storage, err := common.CreateBodyStorage(payload)
	if err != nil {
		return err
	}
	c.Set(common.KeyBodyStorage, storage)
	c.Set("assistant_request", true)
	c.Request.Body = io.NopCloser(storage)
	c.Request.ContentLength = int64(len(payload))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Request.URL.Path = "/v1/chat/completions"
	c.Request.URL.RawPath = ""
	c.Request.RequestURI = "/v1/chat/completions"
	return nil
}

type assistantRelayRecorder struct {
	gin.ResponseWriter
	header      http.Header
	body        bytes.Buffer
	status      int
	wroteHeader bool
}

func newAssistantRelayRecorder(writer gin.ResponseWriter) *assistantRelayRecorder {
	return &assistantRelayRecorder{
		ResponseWriter: writer,
		header:         make(http.Header),
	}
}

func (r *assistantRelayRecorder) Header() http.Header {
	return r.header
}

func (r *assistantRelayRecorder) WriteHeader(statusCode int) {
	if r.wroteHeader {
		return
	}
	r.status = statusCode
	r.wroteHeader = true
}

func (r *assistantRelayRecorder) WriteHeaderNow() {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
}

func (r *assistantRelayRecorder) Write(data []byte) (int, error) {
	r.WriteHeaderNow()
	return r.body.Write(data)
}

func (r *assistantRelayRecorder) WriteString(data string) (int, error) {
	r.WriteHeaderNow()
	return r.body.WriteString(data)
}

func (r *assistantRelayRecorder) Flush() {
	r.WriteHeaderNow()
}

func (r *assistantRelayRecorder) Status() int {
	if !r.wroteHeader {
		return http.StatusOK
	}
	return r.status
}

func (r *assistantRelayRecorder) Size() int {
	if !r.wroteHeader {
		return -1
	}
	return r.body.Len()
}

func (r *assistantRelayRecorder) Written() bool {
	return r.wroteHeader
}

func relayAssistantTurn(c *gin.Context, request assistantOpenAIRequest, rootRequestID string, step int) (int, []byte, error) {
	if err := setAssistantRelayRequest(c, request); err != nil {
		return http.StatusInternalServerError, nil, err
	}

	originalWriter := c.Writer
	recorder := newAssistantRelayRecorder(originalWriter)
	c.Writer = recorder
	c.Set(common.RequestIdKey, fmt.Sprintf("%s-assistant-%d", rootRequestID, step+1))
	defer func() {
		c.Writer = originalWriter
		c.Set(common.RequestIdKey, rootRequestID)
	}()

	Relay(c, types.RelayFormatOpenAI)
	return recorder.Status(), append([]byte(nil), recorder.body.Bytes()...), nil
}

func runAssistantAgent(c *gin.Context, settings setting.AssistantSettings, conversation []assistantOpenAIMessage) {
	timeout := time.Duration(settings.TimeoutSeconds) * time.Second
	if timeout < 5*time.Second {
		timeout = assistantAgentDefaultTimeout
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), timeout)
	defer cancel()
	originalRequest := c.Request
	c.Request = c.Request.WithContext(ctx)
	defer func() {
		c.Request = originalRequest
		common.CleanupBodyStorage(c)
	}()

	rootRequestID := c.GetString(common.RequestIdKey)
	if rootRequestID == "" {
		rootRequestID = common.NewRequestId()
		c.Set(common.RequestIdKey, rootRequestID)
	}

	messages := make([]assistantOpenAIMessage, 1, len(conversation)+1)
	messages[0] = assistantOpenAIMessage{Role: "system", Content: buildAssistantSystemPrompt(settings)}
	messages = append(messages, conversation...)
	maxSteps := settings.MaxSteps
	if maxSteps < 1 {
		maxSteps = 1
	}
	if !settings.AgentLoopEnabled {
		maxSteps = 1
	}
	cacheKey := c.GetString("assistant_cache_key")
	usedTool := false

	for step := 0; step < maxSteps; step++ {
		request := assistantOpenAIRequest{
			Model:       settings.Model,
			Messages:    messages,
			Stream:      false,
			Temperature: 0.2,
			MaxTokens:   900,
		}
		// Reserve the last turn for a final natural-language answer. This
		// makes MaxSteps a hard bound while ensuring a tool call can finish.
		if settings.AgentLoopEnabled && step < maxSteps-1 {
			request.Tools = assistantToolDefinitions()
			request.ToolChoice = "auto"
		}

		status, body, err := relayAssistantTurn(c, request, rootRequestID, step)
		if err != nil {
			writeAssistantError(c, http.StatusInternalServerError, "ASSISTANT_REQUEST_BUILD_FAILED", errors.New("failed to build assistant request"))
			return
		}
		if status < http.StatusOK || status >= http.StatusMultipleChoices {
			writeAssistantRawResponse(c, status, body, "ASSISTANT_UPSTREAM_FAILED")
			return
		}

		response, err := parseAssistantResponse(body)
		if err != nil || len(response.Choices) == 0 {
			writeAssistantError(c, http.StatusBadGateway, "ASSISTANT_INVALID_UPSTREAM_RESPONSE", errors.New("assistant upstream returned an invalid response"))
			return
		}
		message := response.Choices[0].Message
		if len(message.ToolCalls) == 0 {
			if !usedTool && cacheKey != "" {
				storeAssistantCachedResponse(settings, cacheKey, status, body)
				c.Header("X-LMM-Assistant-Cache", "STORE")
			}
			writeAssistantRawResponse(c, status, body, "ASSISTANT_UPSTREAM_FAILED")
			return
		}
		if !settings.AgentLoopEnabled || step >= maxSteps-1 {
			writeAssistantError(c, http.StatusBadGateway, "ASSISTANT_AGENT_MAX_STEPS", errors.New("assistant agent reached its step limit before producing a final answer"))
			return
		}
		if len(message.ToolCalls) > assistantToolCallsPerTurn {
			writeAssistantError(c, http.StatusBadGateway, "ASSISTANT_TOO_MANY_TOOL_CALLS", errors.New("assistant requested too many tools in one turn"))
			return
		}

		messages = append(messages, assistantOpenAIMessage{
			Role:      "assistant",
			Content:   assistantResponseContent(message.Content),
			ToolCalls: message.ToolCalls,
		})
		usedTool = true
		for index, call := range message.ToolCalls {
			result := executeAssistantTool(c, call)
			resultJSON, marshalErr := json.Marshal(result)
			if marshalErr != nil {
				resultJSON = []byte(`{"ok":false,"error":"failed to encode tool result"}`)
			}
			callID := strings.TrimSpace(call.ID)
			if callID == "" {
				callID = fmt.Sprintf("assistant-call-%d-%d", step+1, index+1)
			}
			messages = append(messages, assistantOpenAIMessage{
				Role:       "tool",
				Content:    string(resultJSON),
				ToolCallID: callID,
			})
		}
	}

	writeAssistantError(c, http.StatusBadGateway, "ASSISTANT_AGENT_MAX_STEPS", errors.New("assistant agent reached its step limit"))
}

func parseAssistantResponse(body []byte) (assistantOpenAIResponse, error) {
	var response assistantOpenAIResponse
	if len(body) == 0 {
		return response, errors.New("empty assistant response")
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return response, err
	}
	return response, nil
}

func assistantResponseContent(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var builder strings.Builder
		for _, part := range parts {
			if part.Type == "text" || part.Type == "output_text" || part.Type == "" {
				builder.WriteString(part.Text)
			}
		}
		return builder.String()
	}
	return ""
}

func writeAssistantRawResponse(c *gin.Context, status int, body []byte, fallbackCode string) {
	if len(body) == 0 {
		writeAssistantError(c, http.StatusBadGateway, fallbackCode, errors.New("assistant upstream returned an empty response"))
		return
	}
	c.Data(status, "application/json; charset=utf-8", body)
}

func executeAssistantTool(c *gin.Context, call assistantOpenAIToolCall) map[string]any {
	name := strings.TrimSpace(call.Function.Name)
	arguments := strings.TrimSpace(call.Function.Arguments)
	if arguments == "" {
		arguments = "{}"
	}
	if len(arguments) > assistantToolArgumentsMaxBytes {
		return map[string]any{"ok": false, "error": "tool arguments are too large"}
	}
	var input map[string]any
	if err := json.Unmarshal([]byte(arguments), &input); err != nil {
		return map[string]any{"ok": false, "error": "tool arguments must be valid JSON"}
	}

	switch name {
	case "get_service_facts":
		baseURL := strings.TrimRight(system_setting.ServerAddress, "/")
		if baseURL == "" {
			baseURL = "the /v1 endpoint shown in the current console"
		} else {
			baseURL += "/v1"
		}
		return map[string]any{
			"ok":                   true,
			"base_url":             baseURL,
			"default_model":        setting.GetAssistantSettings().Model,
			"api_keys_are_private": true,
			"key_management_path":  "/keys",
			"write_actions":        "require explicit confirmation in the UI",
		}
	case "calculate_cost":
		return executeAssistantCostTool(input)
	case "get_account_access":
		return executeAssistantAccountTool(c.GetInt("id"))
	case "get_setup_guide":
		return executeAssistantSetupTool(input)
	case "request_create_key":
		return map[string]any{
			"ok":             true,
			"status":         "confirmation_required",
			"action":         "create_key",
			"ui_path":        "/keys",
			"message":        "Ask the user to confirm key creation in the UI; do not claim that a key exists yet.",
			"requested_name": inputString(input, "name"),
		}
	case "request_human_support":
		return map[string]any{
			"ok":            true,
			"status":        "confirmation_required",
			"action":        "human_support",
			"ui_path":       "/support",
			"message":       "Ask the user to confirm sending this message to an administrator.",
			"draft_message": inputString(input, "message"),
		}
	default:
		return map[string]any{"ok": false, "error": "unknown assistant tool"}
	}
}

func executeAssistantCostTool(input map[string]any) map[string]any {
	inputTokens, okInput := inputNumber(input, "input_tokens")
	outputTokens, okOutput := inputNumber(input, "output_tokens")
	inputPrice, okInputPrice := inputNumber(input, "input_usd_per_million")
	outputPrice, okOutputPrice := inputNumber(input, "output_usd_per_million")
	if !okInput || !okOutput || !okInputPrice || !okOutputPrice || inputTokens < 0 || outputTokens < 0 || inputPrice < 0 || outputPrice < 0 {
		return map[string]any{"ok": false, "error": "token counts and prices must be non-negative numbers"}
	}
	ratio := 1.0
	if suppliedRatio, exists := inputNumber(input, "group_ratio"); exists {
		ratio = suppliedRatio
	}
	if ratio < 0 || math.IsNaN(ratio) || math.IsInf(ratio, 0) {
		return map[string]any{"ok": false, "error": "group ratio must be a non-negative finite number"}
	}
	inputCost := inputTokens / 1_000_000 * inputPrice
	outputCost := outputTokens / 1_000_000 * outputPrice
	return map[string]any{
		"ok":              true,
		"input_cost_usd":  inputCost * ratio,
		"output_cost_usd": outputCost * ratio,
		"total_cost_usd":  (inputCost + outputCost) * ratio,
		"group_ratio":     ratio,
		"formula":         "(input_tokens / 1,000,000 × input price + output_tokens / 1,000,000 × output price) × group ratio",
	}
}

func executeAssistantAccountTool(userID int) map[string]any {
	if userID <= 0 {
		return map[string]any{"ok": false, "error": "signed-in account is unavailable"}
	}
	user, err := model.GetUserCache(userID)
	if err != nil {
		return map[string]any{"ok": false, "error": "account access could not be loaded"}
	}
	access, err := model.GetDeveloperAccessStateForUserBase(user)
	if err != nil {
		return map[string]any{"ok": false, "error": "developer access could not be loaded"}
	}
	trust, err := model.GetTrustLevelInfoForUserBase(user)
	if err != nil {
		return map[string]any{"ok": false, "error": "trust level could not be loaded"}
	}
	return map[string]any{
		"ok":                       true,
		"trust_level":              trust.Level,
		"developer_access_granted": access.Granted,
		"paid_activation_complete": access.PaidActivationComplete,
		"console_activated":        user.ConsoleActivatedAt > 0,
		"next_step":                "Use the profile and API key pages for account changes.",
	}
}

func executeAssistantSetupTool(input map[string]any) map[string]any {
	platform := strings.ToLower(strings.TrimSpace(inputString(input, "platform")))
	topic := strings.ToLower(strings.TrimSpace(inputString(input, "topic")))
	if platform != "windows" && platform != "linux" && platform != "macos" {
		return map[string]any{"ok": false, "error": "platform must be windows, linux, or macos"}
	}
	if topic != "claude-code" && topic != "cc-switch" && topic != "chatgpt-client" {
		return map[string]any{"ok": false, "error": "topic is not supported"}
	}
	steps := []string{
		"Install the official client or package for the selected platform and keep it updated.",
		"Use the console's OpenAI-compatible Base URL with the /v1 suffix.",
		"Choose the exact Model ID shown in the model list; do not substitute a display name.",
		"Create or copy an API key only from the API key page and keep it private.",
	}
	if topic == "cc-switch" {
		steps = append(steps,
			"Open CC Switch, add a provider, then fill Base URL, Model ID, and API key in the provider fields.",
			"Send a small test request before changing the active profile.",
		)
	} else if topic == "claude-code" {
		steps = append(steps,
			"Install Claude Code using the current official instructions for your platform.",
			"If the client exposes an OpenAI-compatible provider setting, use the same Base URL, Model ID, and key fields.",
		)
	} else {
		steps = append(steps,
			"Open the desktop or compatible ChatGPT client settings and select a custom OpenAI-compatible endpoint if supported.",
			"Verify the endpoint and model with a short test conversation.",
		)
	}
	return map[string]any{"ok": true, "platform": platform, "topic": topic, "steps": steps}
}

func inputString(input map[string]any, key string) string {
	value, _ := input[key].(string)
	return strings.TrimSpace(value)
}

func inputNumber(input map[string]any, key string) (float64, bool) {
	value, exists := input[key]
	if !exists {
		return 0, false
	}
	var number float64
	switch typed := value.(type) {
	case float64:
		number = typed
	case json.Number:
		parsed, err := typed.Float64()
		if err != nil {
			return 0, false
		}
		number = parsed
	default:
		return 0, false
	}
	if math.IsNaN(number) || math.IsInf(number, 0) {
		return 0, false
	}
	return number, true
}
