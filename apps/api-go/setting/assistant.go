package setting

import (
	"errors"
	"math"
	"strconv"
	"strings"
	"sync"
)

const (
	AssistantEnabledOptionKey         = "AssistantEnabled"
	AssistantModelOptionKey           = "AssistantModel"
	AssistantWeeklyCreditUSDOptionKey = "AssistantWeeklyCreditUSD"
	DefaultAssistantModel             = "deepseek-v4-flash"
)

type AssistantSettings struct {
	Enabled         bool
	Model           string
	WeeklyCreditUSD float64
}

var (
	assistantSettingsMutex sync.RWMutex
	assistantSettings      = AssistantSettings{
		Enabled:         true,
		Model:           DefaultAssistantModel,
		WeeklyCreditUSD: 1,
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
	}
	return nil
}
