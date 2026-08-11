package setting

import (
	"errors"
	"math"
	"strconv"
	"strings"
	"sync"
)

const (
	AssistantEnabledOptionKey          = "AssistantEnabled"
	AssistantModelOptionKey            = "AssistantModel"
	AssistantWeeklyCreditUSDOptionKey  = "AssistantWeeklyCreditUSD"
	AssistantAgentLoopEnabledOptionKey = "AssistantAgentLoopEnabled"
	AssistantMaxStepsOptionKey         = "AssistantMaxSteps"
	AssistantTimeoutSecondsOptionKey   = "AssistantTimeoutSeconds"
	AssistantCacheEnabledOptionKey     = "AssistantCacheEnabled"
	AssistantCacheTTLMinutesOptionKey  = "AssistantCacheTTLMinutes"
	DefaultAssistantModel              = "deepseek-v4-flash"
)

type AssistantSettings struct {
	Enabled          bool
	Model            string
	WeeklyCreditUSD  float64
	AgentLoopEnabled bool
	MaxSteps         int
	TimeoutSeconds   int
	CacheEnabled     bool
	CacheTTLMinutes  int
}

var (
	assistantSettingsMutex sync.RWMutex
	assistantSettings      = AssistantSettings{
		Enabled:          true,
		Model:            DefaultAssistantModel,
		WeeklyCreditUSD:  1,
		AgentLoopEnabled: true,
		MaxSteps:         6,
		TimeoutSeconds:   45,
		CacheEnabled:     true,
		CacheTTLMinutes:  1440,
	}
)

func GetAssistantSettings() AssistantSettings {
	assistantSettingsMutex.RLock()
	defer assistantSettingsMutex.RUnlock()
	return assistantSettings
}

func SetAssistantEnabled(enabled bool) {
	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.Enabled = enabled
}

func UpdateAssistantModel(value string) error {
	model := strings.TrimSpace(value)
	if model == "" {
		return errors.New("assistant model is required")
	}
	if len(model) > 128 {
		return errors.New("assistant model must be at most 128 characters")
	}

	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.Model = model
	return nil
}

func UpdateAssistantWeeklyCreditUSD(value string) error {
	credit, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || math.IsNaN(credit) || math.IsInf(credit, 0) || credit < 0 || credit > 1000 {
		return errors.New("assistant weekly credit must be between 0 and 1000 USD")
	}

	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.WeeklyCreditUSD = credit
	return nil
}

func SetAssistantAgentLoopEnabled(enabled bool) {
	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.AgentLoopEnabled = enabled
}

func UpdateAssistantMaxSteps(value string) error {
	steps, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || steps < 1 || steps > 12 {
		return errors.New("assistant max steps must be between 1 and 12")
	}

	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.MaxSteps = steps
	return nil
}

func UpdateAssistantTimeoutSeconds(value string) error {
	seconds, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || seconds < 5 || seconds > 120 {
		return errors.New("assistant timeout must be between 5 and 120 seconds")
	}

	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.TimeoutSeconds = seconds
	return nil
}

func SetAssistantCacheEnabled(enabled bool) {
	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.CacheEnabled = enabled
}

func UpdateAssistantCacheTTLMinutes(value string) error {
	minutes, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || minutes < 0 || minutes > 10080 {
		return errors.New("assistant cache TTL must be between 0 and 10080 minutes")
	}

	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	assistantSettings.CacheTTLMinutes = minutes
	return nil
}

func ValidateAssistantOption(key string, value string) error {
	switch key {
	case AssistantModelOptionKey:
		model := strings.TrimSpace(value)
		if model == "" {
			return errors.New("assistant model is required")
		}
		if len(model) > 128 {
			return errors.New("assistant model must be at most 128 characters")
		}
	case AssistantWeeklyCreditUSDOptionKey:
		credit, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil || math.IsNaN(credit) || math.IsInf(credit, 0) || credit < 0 || credit > 1000 {
			return errors.New("assistant weekly credit must be between 0 and 1000 USD")
		}
	case AssistantMaxStepsOptionKey:
		steps, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil || steps < 1 || steps > 12 {
			return errors.New("assistant max steps must be between 1 and 12")
		}
	case AssistantTimeoutSecondsOptionKey:
		seconds, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil || seconds < 5 || seconds > 120 {
			return errors.New("assistant timeout must be between 5 and 120 seconds")
		}
	case AssistantCacheTTLMinutesOptionKey:
		minutes, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil || minutes < 0 || minutes > 10080 {
			return errors.New("assistant cache TTL must be between 0 and 10080 minutes")
		}
	}
	return nil
}
