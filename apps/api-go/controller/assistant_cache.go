package controller

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/pkg/cachex"
	"github.com/QuantumNous/new-api/setting"
	"github.com/samber/hot"
)

const assistantResponseCacheNamespace = "new-api:assistant-response:v1"

type assistantCachedResponse struct {
	Status int    `json:"status"`
	Body   []byte `json:"body"`
}

var (
	assistantResponseCacheOnce sync.Once
	assistantResponseCache     *cachex.HybridCache[assistantCachedResponse]
)

func getAssistantResponseCache() *cachex.HybridCache[assistantCachedResponse] {
	assistantResponseCacheOnce.Do(func() {
		assistantResponseCache = cachex.NewHybridCache[assistantCachedResponse](cachex.HybridCacheConfig[assistantCachedResponse]{
			Namespace: cachex.Namespace(assistantResponseCacheNamespace),
			Redis:     common.RDB,
			RedisEnabled: func() bool {
				return common.RedisEnabled && common.RDB != nil
			},
			RedisCodec: cachex.JSONCodec[assistantCachedResponse]{},
			Memory: func() *hot.HotCache[string, assistantCachedResponse] {
				return hot.NewHotCache[string, assistantCachedResponse](hot.LRU, 2048).
					WithTTL(7 * 24 * time.Hour).
					WithJanitor().
					Build()
			},
		})
	})
	return assistantResponseCache
}

type assistantCacheContext struct {
	UserID                   int                      `json:"user_id"`
	Username                 string                   `json:"username,omitempty"`
	Email                    string                   `json:"email,omitempty"`
	EmailDomain              string                   `json:"email_domain,omitempty"`
	EmailCategory            string                   `json:"email_category,omitempty"`
	AuthProviders            []string                 `json:"auth_providers,omitempty"`
	AccessLevel              string                   `json:"access_level"`
	DeveloperAccessGranted   bool                     `json:"developer_access_granted"`
	AccessReviewStatus       string                   `json:"access_review_status,omitempty"`
	PaymentMethodsHidden     bool                     `json:"payment_methods_hidden"`
	PaymentRestrictionCauses []string                 `json:"payment_restriction_causes,omitempty"`
	CustomerProfile          assistantCustomerProfile `json:"customer_profile"`
	Intent                   string                   `json:"current_intent,omitempty"`
	ProfileSignals           []string                 `json:"profile_signals,omitempty"`
}

func toAssistantCacheContext(context assistantUserContext) assistantCacheContext {
	return assistantCacheContext{
		UserID:                   context.UserID,
		Username:                 context.Username,
		Email:                    context.Email,
		EmailDomain:              context.EmailDomain,
		EmailCategory:            context.EmailCategory,
		AuthProviders:            append([]string(nil), context.AuthProviders...),
		AccessLevel:              context.AccessLevel,
		DeveloperAccessGranted:   context.DeveloperAccessGranted,
		AccessReviewStatus:       context.AccessReviewStatus,
		PaymentMethodsHidden:     context.PaymentMethodsHidden,
		PaymentRestrictionCauses: append([]string(nil), context.PaymentRestrictionCauses...),
		CustomerProfile:          context.CustomerProfile,
		Intent:                   context.Intent,
		ProfileSignals:           append([]string(nil), context.ProfileSignals...),
	}
}

func assistantCacheConversation(conversation []assistantOpenAIMessage) []assistantOpenAIMessage {
	result := make([]assistantOpenAIMessage, len(conversation))
	copy(result, conversation)
	for index := range result {
		result[index].Content = strings.ToLower(strings.Join(strings.Fields(result[index].Content), " "))
	}
	return result
}

func assistantCacheKey(settings setting.AssistantSettings, conversation []assistantOpenAIMessage, contexts ...assistantUserContext) string {
	if !settings.CacheEnabled || settings.CacheTTLMinutes <= 0 || len(conversation) != 1 || conversation[0].Role != "user" {
		return ""
	}
	var userContext assistantUserContext
	if len(contexts) > 0 {
		userContext = contexts[0]
	}

	fingerprint := struct {
		Version          string                   `json:"version"`
		Model            string                   `json:"model"`
		SystemPrompt     string                   `json:"system_prompt"`
		AgentLoopEnabled bool                     `json:"agent_loop_enabled"`
		MaxSteps         int                      `json:"max_steps"`
		TimeoutSeconds   int                      `json:"timeout_seconds"`
		TTLMinutes       int                      `json:"ttl_minutes"`
		UserContext      assistantCacheContext    `json:"user_context"`
		Conversation     []assistantOpenAIMessage `json:"conversation"`
	}{
		Version:          "assistant-cache-v1",
		Model:            settings.Model,
		SystemPrompt:     buildAssistantSystemPrompt(settings, userContext),
		AgentLoopEnabled: settings.AgentLoopEnabled,
		MaxSteps:         settings.MaxSteps,
		TimeoutSeconds:   settings.TimeoutSeconds,
		TTLMinutes:       settings.CacheTTLMinutes,
		UserContext:      toAssistantCacheContext(userContext),
		Conversation:     assistantCacheConversation(conversation),
	}
	raw, err := json.Marshal(fingerprint)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}

func getAssistantCachedResponse(key string) (assistantCachedResponse, bool) {
	if key == "" {
		return assistantCachedResponse{}, false
	}
	value, found, err := getAssistantResponseCache().Get(key)
	if err != nil {
		common.SysLog("assistant response cache read failed: " + err.Error())
		return assistantCachedResponse{}, false
	}
	if !found || value.Status < 200 || value.Status >= 300 || len(value.Body) == 0 {
		return assistantCachedResponse{}, false
	}
	return value, true
}

func storeAssistantCachedResponse(settings setting.AssistantSettings, key string, status int, body []byte) {
	if key == "" || !settings.CacheEnabled || settings.CacheTTLMinutes <= 0 || status < 200 || status >= 300 || len(body) == 0 {
		return
	}
	value := assistantCachedResponse{Status: status, Body: append([]byte(nil), body...)}
	if err := getAssistantResponseCache().SetWithTTL(key, value, time.Duration(settings.CacheTTLMinutes)*time.Minute); err != nil {
		common.SysLog("assistant response cache write failed: " + err.Error())
	}
}
