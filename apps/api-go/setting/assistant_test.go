package setting

import (
	"strconv"
	"testing"
)

func TestAssistantDefaultsAndValidation(t *testing.T) {
	settings := GetAssistantSettings()
	if !settings.Enabled {
		t.Fatal("assistant should be enabled by default")
	}
	if settings.Model != DefaultAssistantModel {
		t.Fatalf("unexpected default model: %q", settings.Model)
	}
	if settings.WeeklyCreditUSD != 1 {
		t.Fatalf("unexpected weekly credit: %v", settings.WeeklyCreditUSD)
	}
	if !settings.AgentLoopEnabled || settings.MaxSteps != 6 || settings.TimeoutSeconds != 45 || !settings.CacheEnabled || settings.CacheTTLMinutes != 1440 {
		t.Fatalf("unexpected assistant runtime defaults: %+v", settings)
	}

	invalid := map[string]string{
		AssistantModelOptionKey:           " ",
		AssistantWeeklyCreditUSDOptionKey: "-0.01",
		AssistantMaxStepsOptionKey:        "13",
		AssistantTimeoutSecondsOptionKey:  "4",
		AssistantCacheTTLMinutesOptionKey: "10081",
		"nan-credit":                      "NaN",
	}
	for key, value := range invalid {
		optionKey := key
		if key == "nan-credit" {
			optionKey = AssistantWeeklyCreditUSDOptionKey
		}
		if err := ValidateAssistantOption(optionKey, value); err == nil {
			t.Fatalf("expected validation error for %s=%q", key, value)
		}
	}
}

func TestAssistantSettingsUpdates(t *testing.T) {
	original := GetAssistantSettings()
	t.Cleanup(func() {
		SetAssistantEnabled(original.Enabled)
		_ = UpdateAssistantModel(original.Model)
		_ = UpdateAssistantWeeklyCreditUSD(strconv.FormatFloat(original.WeeklyCreditUSD, 'f', -1, 64))
		SetAssistantAgentLoopEnabled(original.AgentLoopEnabled)
		_ = UpdateAssistantMaxSteps(strconv.Itoa(original.MaxSteps))
		_ = UpdateAssistantTimeoutSeconds(strconv.Itoa(original.TimeoutSeconds))
		SetAssistantCacheEnabled(original.CacheEnabled)
		_ = UpdateAssistantCacheTTLMinutes(strconv.Itoa(original.CacheTTLMinutes))
	})

	SetAssistantEnabled(false)
	if err := UpdateAssistantModel(" custom-model "); err != nil {
		t.Fatal(err)
	}
	if err := UpdateAssistantWeeklyCreditUSD("2.5"); err != nil {
		t.Fatal(err)
	}
	SetAssistantAgentLoopEnabled(false)
	if err := UpdateAssistantMaxSteps("9"); err != nil {
		t.Fatal(err)
	}
	if err := UpdateAssistantTimeoutSeconds("60"); err != nil {
		t.Fatal(err)
	}
	SetAssistantCacheEnabled(false)
	if err := UpdateAssistantCacheTTLMinutes("30"); err != nil {
		t.Fatal(err)
	}

	settings := GetAssistantSettings()
	if settings.Enabled || settings.Model != "custom-model" || settings.WeeklyCreditUSD != 2.5 || settings.AgentLoopEnabled || settings.MaxSteps != 9 || settings.TimeoutSeconds != 60 || settings.CacheEnabled || settings.CacheTTLMinutes != 30 {
		t.Fatalf("unexpected updated settings: %+v", settings)
	}
}
