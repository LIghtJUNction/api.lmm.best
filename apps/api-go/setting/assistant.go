package setting

import (
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

const (
	AssistantEnabledOptionKey = "AssistantEnabled"
	AssistantModelOptionKey   = "AssistantModel"
	// AssistantWeeklyCreditUSDOptionKey is retained only so older consoles can
	// read and submit their retired field without affecting runtime funding.
	AssistantWeeklyCreditUSDOptionKey  = "AssistantWeeklyCreditUSD"
	AssistantAgentLoopEnabledOptionKey = "AssistantAgentLoopEnabled"
	AssistantMaxStepsOptionKey         = "AssistantMaxSteps"
	AssistantTimeoutSecondsOptionKey   = "AssistantTimeoutSeconds"
	AssistantCacheEnabledOptionKey     = "AssistantCacheEnabled"
	AssistantCacheTTLMinutesOptionKey  = "AssistantCacheTTLMinutes"
	AssistantPersonaOptionKey          = "AssistantPersona"
	AssistantSystemPromptOptionKey     = "AssistantSystemPrompt"
	AssistantSearchURLOptionKey        = "AssistantSearchURL"
	AssistantSearchAPIKeyOptionKey     = "AssistantSearchAPIKey"
	AssistantSkillsOptionKey           = "AssistantSkills"
	DefaultAssistantModel              = "deepseek-v4-flash"
)

type AssistantSettings struct {
	Enabled          bool
	Model            string
	AgentLoopEnabled bool
	MaxSteps         int
	TimeoutSeconds   int
	CacheEnabled     bool
	CacheTTLMinutes  int
	Persona          string
	SystemPrompt     string
	SearchURL        string
	SearchAPIKey     string
	Skills           string
}

var (
	assistantSettingsMutex sync.RWMutex
	assistantSettings      = AssistantSettings{
		Enabled:          true,
		Model:            DefaultAssistantModel,
		AgentLoopEnabled: true,
		MaxSteps:         6,
		TimeoutSeconds:   45,
		CacheEnabled:     true,
		CacheTTLMinutes:  1440,
		Persona:          "",
		SystemPrompt:     "",
		SearchURL:        "",
		SearchAPIKey:     "",
		Skills:           "",
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

func updateAssistantText(target *string, value string, maxLength int, message string) error {
	value = strings.TrimSpace(value)
	if len([]rune(value)) > maxLength {
		return errors.New(message)
	}
	assistantSettingsMutex.Lock()
	defer assistantSettingsMutex.Unlock()
	*target = value
	return nil
}

func UpdateAssistantPersona(value string) error {
	return updateAssistantText(&assistantSettings.Persona, value, 2000, "assistant persona must be at most 2000 characters")
}

func UpdateAssistantSystemPrompt(value string) error {
	return updateAssistantText(&assistantSettings.SystemPrompt, value, 8000, "assistant system prompt must be at most 8000 characters")
}

func UpdateAssistantSearchURL(value string) error {
	if err := ValidateAssistantSearchURL(value); err != nil {
		return err
	}
	return updateAssistantText(&assistantSettings.SearchURL, value, 512, "assistant search URL must be at most 512 characters")
}

func UpdateAssistantSearchAPIKey(value string) error {
	return updateAssistantText(&assistantSettings.SearchAPIKey, value, 512, "assistant search API key must be at most 512 characters")
}

func UpdateAssistantSkills(value string) error {
	return updateAssistantText(&assistantSettings.Skills, value, 12000, "assistant skills must be at most 12000 characters")
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
	case AssistantPersonaOptionKey:
		if len([]rune(strings.TrimSpace(value))) > 2000 {
			return errors.New("assistant persona must be at most 2000 characters")
		}
	case AssistantSystemPromptOptionKey:
		if len([]rune(strings.TrimSpace(value))) > 8000 {
			return errors.New("assistant system prompt must be at most 8000 characters")
		}
	case AssistantSearchURLOptionKey:
		return ValidateAssistantSearchURL(value)
	case AssistantSearchAPIKeyOptionKey:
		if len([]rune(strings.TrimSpace(value))) > 512 {
			return errors.New("assistant search API key must be at most 512 characters")
		}
	case AssistantSkillsOptionKey:
		if len([]rune(strings.TrimSpace(value))) > 12000 {
			return errors.New("assistant skills must be at most 12000 characters")
		}
	}
	return nil
}

// ValidateAssistantSearchURL checks the administrator-supplied search
// endpoint's syntax and rejects address literals that cannot be a public
// search provider. Hostnames are checked again at connection time because DNS
// answers can change after an option is saved.
func ValidateAssistantSearchURL(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	parsed, err := url.ParseRequestURI(value)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return errors.New("assistant search URL must be an absolute HTTP or HTTPS URL")
	}
	if parsed.User != nil {
		return errors.New("assistant search URL must not contain embedded credentials")
	}
	hostname := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if hostname == "" {
		return errors.New("assistant search URL must include a host")
	}
	if ip := net.ParseIP(hostname); ip != nil && !IsAssistantSearchPublicIP(ip) {
		return errors.New("assistant search URL must resolve to a public address")
	}
	return nil
}

func IsAssistantSearchPublicIP(ip net.IP) bool {
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() {
		return false
	}
	if ip4 := ip.To4(); ip4 != nil {
		// Carrier-grade NAT, benchmarking, documentation, and reserved ranges
		// are not public service addresses even though some are global unicast.
		if ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
			return false
		}
		if ip4[0] == 192 && ip4[1] == 0 && ip4[2] == 0 {
			return false
		}
		if ip4[0] == 192 && ip4[1] == 0 && ip4[2] == 2 {
			return false
		}
		if ip4[0] == 198 && ip4[1] == 18 {
			return false
		}
		if ip4[0] == 198 && ip4[1] == 19 {
			return false
		}
		if ip4[0] == 198 && ip4[1] == 51 && ip4[2] == 100 {
			return false
		}
		if ip4[0] == 203 && ip4[1] == 0 && ip4[2] == 113 {
			return false
		}
	}
	return true
}
