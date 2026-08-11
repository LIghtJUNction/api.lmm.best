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
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/relaykit/types"
	"github.com/QuantumNous/new-api/service"
	"github.com/QuantumNous/new-api/setting"
	"github.com/QuantumNous/new-api/setting/operation_setting"
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
				Name:        "get_available_models",
				Description: "Return the model IDs and usable routing groups available to the signed-in user. Never invent a model ID.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_plan_offers",
				Description: "Return current enabled subscription plans and configured top-up discounts for comparison. Use exact live values and do not invent promotions.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_invitation_rewards",
				Description: "Explain the signed-in user's invitation code, reward status, and current inviter/invitee reward configuration without exposing secrets.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_bounty_guide",
				Description: "Return the current safe workflow for publishing, funding, reviewing, tipping, and settling an open-source bounty.",
				Parameters:  emptyObjectSchema(),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_usage_summary",
				Description: "Summarize the signed-in user's historical consume calls by model and group. Use this for usage statistics instead of exposing raw logs.",
				Parameters: objectSchema(map[string]any{
					"days": map[string]any{"type": "integer", "minimum": 1, "maximum": 90},
				}, nil),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "search_web",
				Description: "Search the administrator-configured web search API for current software installation or platform information. If no search API is configured, report that limitation.",
				Parameters: objectSchema(map[string]any{
					"query": map[string]any{"type": "string", "minLength": 2, "maxLength": 500},
				}, []string{"query"}),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "get_setup_guide",
				Description: "Return verified platform-specific install commands and gateway configuration for Claude Code, CC Switch, Claude Desktop, Codex, and compatible clients. Use this instead of guessing client capabilities or endpoint formats.",
				Parameters: objectSchema(map[string]any{
					"platform": map[string]any{"type": "string", "enum": []string{"windows", "linux", "macos"}},
					"topic":    map[string]any{"type": "string", "enum": []string{"claude-code", "cc-switch", "claude-desktop", "chatgpt-client", "codex", "cursor", "open-webui", "other-openai-compatible"}},
				}, []string{"platform", "topic"}),
			},
		},
		{
			Type: "function",
			Function: assistantOpenAIToolFunction{
				Name:        "request_create_key",
				Description: "Prepare creation of an API key. First call without a group to load the signed-in user's live group choices, then ask the user to choose one exact group. Only after that choice may you request explicit confirmation; never claim a key was created from this tool.",
				Parameters: objectSchema(map[string]any{
					"name":  map[string]any{"type": "string", "maxLength": 50},
					"group": map[string]any{"type": "string", "maxLength": 64},
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
	case "get_available_models":
		return executeAssistantModelsTool(c.GetInt("id"))
	case "get_plan_offers":
		return executeAssistantPlanOffersTool(c.GetInt("id"))
	case "get_invitation_rewards":
		return executeAssistantInvitationTool(c.GetInt("id"))
	case "get_bounty_guide":
		return executeAssistantBountyTool()
	case "get_usage_summary":
		return executeAssistantUsageTool(c.GetInt("id"), input)
	case "search_web":
		return executeAssistantSearchTool(c, input)
	case "get_setup_guide":
		return executeAssistantSetupTool(input)
	case "request_create_key":
		if c == nil {
			return map[string]any{"ok": false, "error": "signed-in account is unavailable"}
		}
		return executeAssistantCreateKeyRequestTool(c.GetInt("id"), input)
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

func executeAssistantModelsTool(userID int) map[string]any {
	if userID <= 0 {
		return map[string]any{"ok": false, "error": "signed-in account is unavailable"}
	}
	user, err := model.GetUserCache(userID)
	if err != nil {
		return map[string]any{"ok": false, "error": "available models could not be loaded"}
	}
	groups := service.GetUserUsableGroups(user.Group)
	groupNames := make([]string, 0, len(groups))
	for group := range groups {
		groupNames = append(groupNames, group)
	}
	sort.Strings(groupNames)
	models := service.GetGroupsEnabledModels(groupNames)
	sort.Strings(models)
	return map[string]any{
		"ok":              true,
		"groups":          groupNames,
		"model_ids":       models,
		"default_model":   setting.GetAssistantSettings().Model,
		"model_list_path": "/models",
	}
}

func executeAssistantPlanOffersTool(userID int) map[string]any {
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
	result := map[string]any{
		"ok":                           access.Granted,
		"developer_access_granted":     access.Granted,
		"plans":                        []any{},
		"topup_discounts":              []any{},
		"payment_compliance_confirmed": operation_setting.IsPaymentComplianceConfirmed(),
	}
	if !access.Granted {
		result["error"] = "L1 access is required to view plans and top-up discounts"
		result["next_step"] = "Ask the user to submit an administrator access request from the onboarding assistant."
		return result
	}
	if !operation_setting.IsPaymentComplianceConfirmed() {
		result["message"] = "Current plan offers are unavailable until payment compliance is confirmed."
		return result
	}
	if model.DB == nil || common.QuotaPerUnit <= 0 {
		return map[string]any{"ok": false, "error": "subscription plans are temporarily unavailable"}
	}
	var plans []model.SubscriptionPlan
	if err := model.DB.Where("enabled = ?", true).Order("sort_order desc, id desc").Find(&plans).Error; err != nil {
		return map[string]any{"ok": false, "error": "subscription plans could not be loaded"}
	}
	planValues := make([]map[string]any, 0, len(plans))
	for _, plan := range plans {
		plan.NormalizeDefaults()
		planValues = append(planValues, map[string]any{
			"id":                 plan.Id,
			"title":              plan.Title,
			"subtitle":           plan.Subtitle,
			"price_amount":       plan.PriceAmount,
			"currency":           plan.Currency,
			"duration_unit":      plan.DurationUnit,
			"duration_value":     plan.DurationValue,
			"total_quota":        plan.TotalAmount,
			"total_quota_usd":    float64(plan.TotalAmount) / common.QuotaPerUnit,
			"quota_reset_period": plan.QuotaResetPeriod,
			"upgrade_group":      plan.UpgradeGroup,
		})
	}
	discountValues := make([]map[string]any, 0, len(operation_setting.GetPaymentSetting().AmountDiscount))
	for amount, multiplier := range operation_setting.GetPaymentSetting().AmountDiscount {
		discountValues = append(discountValues, map[string]any{
			"amount":          amount,
			"multiplier":      multiplier,
			"savings_percent": (1 - multiplier) * 100,
		})
	}
	sort.Slice(discountValues, func(i, j int) bool {
		return discountValues[i]["amount"].(int) < discountValues[j]["amount"].(int)
	})
	result["plans"] = planValues
	result["topup_discounts"] = discountValues
	return result
}

func executeAssistantInvitationTool(userID int) map[string]any {
	if userID <= 0 {
		return map[string]any{"ok": false, "error": "signed-in account is unavailable"}
	}
	user, err := model.GetUserById(userID, false)
	if err != nil {
		return map[string]any{"ok": false, "error": "invitation information could not be loaded"}
	}
	result := map[string]any{
		"ok":                           true,
		"affiliate_code":               user.AffCode,
		"invited_count":                user.AffCount,
		"pending_reward_usd":           float64(user.AffQuota) / common.QuotaPerUnit,
		"total_reward_usd":             float64(user.AffHistoryQuota) / common.QuotaPerUnit,
		"reward_per_inviter_usd":       float64(common.QuotaForInviter) / common.QuotaPerUnit,
		"reward_per_invitee_usd":       float64(common.QuotaForInvitee) / common.QuotaPerUnit,
		"payment_compliance_confirmed": operation_setting.IsPaymentComplianceConfirmed(),
		"next_step":                    "Open the invitation page to generate or copy the current invitation code.",
	}
	if user.AffCode != "" {
		baseURL := strings.TrimRight(system_setting.ServerAddress, "/")
		if baseURL != "" {
			result["affiliate_link"] = baseURL + "/sign-up?aff=" + url.QueryEscape(user.AffCode)
		}
	}
	if !operation_setting.IsPaymentComplianceConfirmed() {
		result["message"] = "Reward configuration is shown for explanation only; payment-related rewards remain subject to the platform compliance setting."
	}
	return result
}

func executeAssistantBountyTool() map[string]any {
	fee := model.GetOpenSourceBountyFeeConfig()
	return map[string]any{
		"ok": true,
		"steps": []string{
			"Open the open-source bounties page and choose create project.",
			"Provide the repository, issue or pull request, acceptance criteria, gross reward, and number of fixes.",
			"Review the platform fee, net escrow, and total balance debit before publishing.",
			"Publish only after explicitly confirming the funding action.",
			"Review submitted evidence; when work is accepted, settle the fix and optionally add a separate non-refundable tip.",
			"Use the dispute flow when publisher and contributor cannot agree; do not fabricate evidence.",
		},
		"platform_fee_percent": fee.RatePercent,
		"page":                 "/open-source-bounties",
		"message":              "A bounty publisher may give a contributor a tip, but the exact charge and escrow are shown before confirmation.",
	}
}

func executeAssistantUsageTool(userID int, input map[string]any) map[string]any {
	days := 30
	if value, exists := inputNumber(input, "days"); exists {
		days = int(value)
	}
	if days < 1 || days > 90 {
		return map[string]any{"ok": false, "error": "days must be between 1 and 90"}
	}
	end := time.Now().Unix()
	start := time.Now().Add(-time.Duration(days) * 24 * time.Hour).Unix()
	summary, err := model.GetAssistantUsageSummary(userID, start, end, 20)
	if err != nil {
		return map[string]any{"ok": false, "error": "historical usage could not be loaded"}
	}
	return map[string]any{
		"ok":       true,
		"days":     days,
		"source":   "consume logs",
		"summary":  summary,
		"raw_logs": false,
	}
}

func executeAssistantSearchTool(c *gin.Context, input map[string]any) map[string]any {
	query := inputString(input, "query")
	if len([]rune(query)) < 2 {
		return map[string]any{"ok": false, "error": "search query is required"}
	}
	settings := setting.GetAssistantSettings()
	searchURL := strings.TrimSpace(settings.SearchURL)
	if searchURL == "" {
		return map[string]any{"ok": false, "configured": false, "error": "web search is not configured by the administrator"}
	}
	parsed, err := url.Parse(searchURL)
	if err != nil {
		return map[string]any{"ok": false, "error": "configured search URL is invalid"}
	}
	params := parsed.Query()
	params.Set("q", query)
	parsed.RawQuery = params.Encode()
	ctx := context.Background()
	if c != nil && c.Request != nil {
		ctx = c.Request.Context()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return map[string]any{"ok": false, "error": "search request could not be created"}
	}
	if key := strings.TrimSpace(settings.SearchAPIKey); key != "" {
		request.Header.Set("Authorization", "Bearer "+key)
		request.Header.Set("X-API-Key", key)
	}
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return map[string]any{"ok": false, "configured": true, "error": "search provider request failed"}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if err != nil {
		return map[string]any{"ok": false, "configured": true, "error": "search provider response could not be read"}
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return map[string]any{"ok": false, "configured": true, "status": response.StatusCode, "error": "search provider returned an error"}
	}
	var data any
	if json.Unmarshal(body, &data) != nil {
		data = strings.TrimSpace(string(body))
	}
	return map[string]any{"ok": true, "configured": true, "query": query, "results": data}
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
	if topic != "claude-code" && topic != "cc-switch" && topic != "claude-desktop" && topic != "chatgpt-client" && topic != "codex" && topic != "cursor" && topic != "open-webui" && topic != "other-openai-compatible" {
		return map[string]any{"ok": false, "error": "topic is not supported"}
	}
	rootURL := strings.TrimRight(system_setting.ServerAddress, "/")
	if rootURL == "" {
		rootURL = "<SERVICE_ROOT_URL>"
	}
	openAIBaseURL := rootURL + "/v1"
	if rootURL == "<SERVICE_ROOT_URL>" {
		openAIBaseURL = "<OPENAI_BASE_URL>"
	}
	defaultModel := strings.TrimSpace(setting.GetAssistantSettings().Model)
	if defaultModel == "" {
		defaultModel = "<MODEL_ID>"
	}

	result := map[string]any{
		"ok":               true,
		"platform":         platform,
		"topic":            topic,
		"service_root":     rootURL,
		"openai_base_url":  openAIBaseURL,
		"default_model_id": defaultModel,
		"api_key":          "<YOUR_API_KEY>",
		"security_note":    "Create the key in this console, never paste an existing secret into chat, and test with a newly opened terminal or client session.",
	}

	switch topic {
	case "claude-code":
		installCommand := "curl -fsSL https://claude.ai/install.sh | bash"
		configuration := fmt.Sprintf("export ANTHROPIC_BASE_URL=%q\nexport ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'\nexport ANTHROPIC_MODEL=%q\nclaude", rootURL, defaultModel)
		if platform == "windows" {
			installCommand = "winget install Anthropic.ClaudeCode"
			configuration = fmt.Sprintf("$env:ANTHROPIC_BASE_URL=%q\n$env:ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'\n$env:ANTHROPIC_MODEL=%q\nclaude", rootURL, defaultModel)
		} else if platform == "macos" {
			installCommand = "brew install --cask claude-code"
		}
		result["install_command"] = installCommand
		result["configuration"] = configuration
		result["endpoint_format"] = "Anthropic Messages; use the service root without /v1"
		result["steps"] = []string{
			"Install Claude Code with the command returned by this tool, then run claude --version.",
			"Create an API key in this console and replace only the <YOUR_API_KEY> placeholder.",
			"Apply the returned environment variables in a terminal opened for the project, then run claude.",
		}
		result["official_docs"] = "https://code.claude.com/docs/en/setup"
	case "cc-switch":
		installGuide := "Download CC-Switch-v{version}-Windows.msi from the official GitHub Releases page."
		if platform == "macos" {
			installGuide = "brew install --cask cc-switch"
		} else if platform == "linux" {
			installGuide = "Download the official AppImage or distribution package; on Arch Linux use paru -S cc-switch-bin."
		}
		result["install_guide"] = installGuide
		result["provider"] = map[string]any{
			"application": "Claude",
			"env": map[string]string{
				"ANTHROPIC_BASE_URL":   rootURL,
				"ANTHROPIC_AUTH_TOKEN": "<YOUR_API_KEY>",
				"ANTHROPIC_MODEL":      defaultModel,
			},
		}
		result["endpoint_format"] = "Anthropic Messages; use the service root without /v1"
		result["steps"] = []string{
			"Install CC Switch only from its official site or GitHub Releases.",
			"Select Claude, add a Custom provider, and enter the returned service root, model ID, and a newly created API key.",
			"Save and enable the provider, open a new terminal, and send a short test with Claude Code.",
		}
		result["official_docs"] = "https://github.com/farion1231/cc-switch"
	case "claude-desktop":
		result["direct_custom_gateway_supported"] = false
		result["endpoint_format"] = "Anthropic Messages through CC Switch local routing"
		if platform == "linux" {
			result["supported"] = false
			result["limitation"] = "CC Switch currently manages third-party Claude Desktop profiles on Windows and macOS; use Claude Code on Linux for this service."
		} else {
			result["supported"] = true
			result["steps"] = []string{
				"Install and launch the official Claude Desktop app once.",
				"In CC Switch, enable Claude Desktop and import the Claude Code provider or add a custom provider.",
				"Map the Sonnet role to the returned model ID, enable local routing, then fully restart Claude Desktop.",
			}
		}
		result["official_docs"] = "https://code.claude.com/docs/en/desktop-quickstart"
		result["cc_switch_docs"] = "https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/2-providers/2.6-claude-desktop.md"
	case "chatgpt-client":
		result["supported"] = false
		result["direct_custom_gateway_supported"] = false
		result["limitation"] = "The official ChatGPT app uses OpenAI sign-in and does not accept this service's Base URL or API key as a custom provider."
		result["recommended_alternatives"] = []string{"CC Switch", "Codex CLI", "Open WebUI", "another client that explicitly supports custom OpenAI-compatible providers"}
		result["official_download"] = "https://chatgpt.com/download/"
	case "codex":
		apiKeyCommand := "export LMM_API_KEY='<YOUR_API_KEY>'"
		if platform == "windows" {
			apiKeyCommand = "$env:LMM_API_KEY='<YOUR_API_KEY>'"
		}
		result["install_command"] = "npm install -g @openai/codex"
		result["api_key_command"] = apiKeyCommand
		result["config_path"] = "~/.codex/config.toml"
		result["config_toml"] = fmt.Sprintf("model = %q\nmodel_provider = \"lmm\"\n\n[model_providers.lmm]\nname = \"LMM\"\nbase_url = %q\nenv_key = \"LMM_API_KEY\"\nwire_api = \"responses\"", defaultModel, openAIBaseURL)
		result["endpoint_format"] = "OpenAI Responses API; use the /v1 Base URL"
		result["steps"] = []string{
			"Install Codex, then create the user-level ~/.codex/config.toml with the returned provider configuration.",
			"Set LMM_API_KEY in the current shell without writing the key into config.toml.",
			"Run codex in a project directory and verify the provider and model shown by /status.",
		}
		result["official_docs"] = "https://developers.openai.com/codex/cli"
		result["config_reference"] = "https://developers.openai.com/codex/config-reference"
	case "cursor":
		result["endpoint_format"] = "OpenAI-compatible; use the /v1 Base URL only if the installed Cursor version exposes a custom Base URL"
		result["steps"] = []string{
			"Open Cursor Settings and check whether the installed version exposes a custom OpenAI-compatible Base URL.",
			"If supported, enter the returned /v1 Base URL, exact model ID, and a newly created API key.",
			"If the setting is absent, do not assume the official client can use this gateway; choose CC Switch or another compatible client.",
		}
	case "open-webui":
		result["endpoint_format"] = "OpenAI-compatible; use the /v1 Base URL"
		result["steps"] = []string{
			"Open Open WebUI administrator settings and add an OpenAI-compatible connection.",
			"Enter the returned /v1 Base URL and a newly created API key, then refresh the model list.",
			"Select the exact returned model ID and send a short test request.",
		}
		result["official_docs"] = "https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-openai-compatible/"
	case "other-openai-compatible":
		result["endpoint_format"] = "OpenAI-compatible; use the /v1 Base URL"
		result["steps"] = []string{
			"Confirm that the client explicitly supports a custom OpenAI-compatible Base URL.",
			"Enter the returned /v1 Base URL, exact model ID, and a newly created API key.",
			"Send a short test and verify that the client uses a route supported by this service.",
		}
	}
	return result
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
