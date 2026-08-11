package controller

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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

func assistantCacheKey(settings setting.AssistantSettings, conversation []assistantOpenAIMessage) string {
	if !settings.CacheEnabled || settings.CacheTTLMinutes <= 0 || len(conversation) != 1 || conversation[0].Role != "user" {
		return ""
	}

	fingerprint := struct {
		Version          string                   `json:"version"`
		Model            string                   `json:"model"`
		SystemPrompt     string                   `json:"system_prompt"`
		AgentLoopEnabled bool                     `json:"agent_loop_enabled"`
		MaxSteps         int                      `json:"max_steps"`
		TimeoutSeconds   int                      `json:"timeout_seconds"`
		TTLMinutes       int                      `json:"ttl_minutes"`
		Conversation     []assistantOpenAIMessage `json:"conversation"`
	}{
		Version:          "assistant-cache-v1",
		Model:            settings.Model,
		SystemPrompt:     buildAssistantSystemPrompt(settings),
		AgentLoopEnabled: settings.AgentLoopEnabled,
		MaxSteps:         settings.MaxSteps,
		TimeoutSeconds:   settings.TimeoutSeconds,
		TTLMinutes:       settings.CacheTTLMinutes,
		Conversation:     conversation,
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
