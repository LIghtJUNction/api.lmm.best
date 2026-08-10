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

	invalid := map[string]string{
		AssistantModelOptionKey:           " ",
		AssistantWeeklyCreditUSDOptionKey: "-0.01",
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
	})

	SetAssistantEnabled(false)
	if err := UpdateAssistantModel(" custom-model "); err != nil {
		t.Fatal(err)
	}
	if err := UpdateAssistantWeeklyCreditUSD("2.5"); err != nil {
		t.Fatal(err)
	}

	settings := GetAssistantSettings()
	if settings.Enabled || settings.Model != "custom-model" || settings.WeeklyCreditUSD != 2.5 {
		t.Fatalf("unexpected updated settings: %+v", settings)
	}
}
