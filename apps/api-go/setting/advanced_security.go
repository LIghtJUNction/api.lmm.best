package setting

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
)

const (
	AdvancedSecurityEnabledOptionKey      = "AdvancedSecurityEnabled"
	AdvancedSecurityOnPromptOptionKey     = "AdvancedSecurityOnPromptEnabled"
	AdvancedSecurityActionOptionKey       = "AdvancedSecurityAction"
	AdvancedSecurityRulesOptionKey        = "AdvancedSecurityRules"
	AdvancedSecurityActionBlock           = "block"
	AdvancedSecurityActionAudit           = "audit"
	advancedSecurityRuleSetVersion        = 1
	advancedSecurityMaxRules              = 512
	advancedSecurityMaxPatternsPerRule    = 64
	advancedSecurityMaxPatternLength      = 256
	advancedSecurityMaxRuleIDLength       = 64
	advancedSecurityMaxRuleNameLength     = 128
	advancedSecurityMaxRuleCategoryLength = 64
)

// AdvancedSecurityRule is an operator-managed literal rule. Patterns are
// matched case-insensitively by the service's Aho-Corasick matcher.
type AdvancedSecurityRule struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Enabled  bool     `json:"enabled"`
	Patterns []string `json:"patterns"`
}

type AdvancedSecurityRuleSet struct {
	Version int                    `json:"version"`
	Rules   []AdvancedSecurityRule `json:"rules"`
}

type AdvancedSecuritySettings struct {
	Enabled  bool
	OnPrompt bool
	Action   string
	RuleSet  AdvancedSecurityRuleSet
}

var (
	advancedSecuritySettingsMu sync.RWMutex
	advancedSecuritySettings   = AdvancedSecuritySettings{
		Enabled:  false,
		OnPrompt: true,
		Action:   AdvancedSecurityActionBlock,
		RuleSet: AdvancedSecurityRuleSet{
			Version: advancedSecurityRuleSetVersion,
			Rules:   []AdvancedSecurityRule{},
		},
	}
)

func GetAdvancedSecuritySettings() AdvancedSecuritySettings {
	advancedSecuritySettingsMu.RLock()
	defer advancedSecuritySettingsMu.RUnlock()

	settings := advancedSecuritySettings
	settings.RuleSet.Rules = cloneAdvancedSecurityRules(settings.RuleSet.Rules)
	return settings
}

func SetAdvancedSecurityEnabled(enabled bool) {
	advancedSecuritySettingsMu.Lock()
	defer advancedSecuritySettingsMu.Unlock()
	advancedSecuritySettings.Enabled = enabled
}

func SetAdvancedSecurityOnPrompt(enabled bool) {
	advancedSecuritySettingsMu.Lock()
	defer advancedSecuritySettingsMu.Unlock()
	advancedSecuritySettings.OnPrompt = enabled
}

func UpdateAdvancedSecurityAction(value string) error {
	action := strings.ToLower(strings.TrimSpace(value))
	if action != AdvancedSecurityActionBlock && action != AdvancedSecurityActionAudit {
		return fmt.Errorf("advanced security action must be %q or %q", AdvancedSecurityActionBlock, AdvancedSecurityActionAudit)
	}

	advancedSecuritySettingsMu.Lock()
	defer advancedSecuritySettingsMu.Unlock()
	advancedSecuritySettings.Action = action
	return nil
}

func UpdateAdvancedSecurityRules(value string) error {
	ruleSet, err := ParseAdvancedSecurityRules(value)
	if err != nil {
		return err
	}

	advancedSecuritySettingsMu.Lock()
	defer advancedSecuritySettingsMu.Unlock()
	advancedSecuritySettings.RuleSet = ruleSet
	return nil
}

func ShouldCheckAdvancedSecurityPrompt() bool {
	advancedSecuritySettingsMu.RLock()
	defer advancedSecuritySettingsMu.RUnlock()
	return advancedSecuritySettings.Enabled && advancedSecuritySettings.OnPrompt && len(advancedSecuritySettings.RuleSet.Rules) > 0
}

func AdvancedSecurityRulesToJSONString() string {
	settings := GetAdvancedSecuritySettings()
	encoded, err := json.Marshal(settings.RuleSet)
	if err != nil {
		return `{"version":1,"rules":[]}`
	}
	return string(encoded)
}

func ParseAdvancedSecurityRules(value string) (AdvancedSecurityRuleSet, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return emptyAdvancedSecurityRuleSet(), nil
	}

	var ruleSet AdvancedSecurityRuleSet
	if strings.HasPrefix(raw, "[") {
		if err := json.Unmarshal([]byte(raw), &ruleSet.Rules); err != nil {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rules must be valid JSON: %w", err)
		}
		ruleSet.Version = advancedSecurityRuleSetVersion
	} else if err := json.Unmarshal([]byte(raw), &ruleSet); err != nil {
		return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rules must be valid JSON: %w", err)
	}

	if ruleSet.Version == 0 {
		ruleSet.Version = advancedSecurityRuleSetVersion
	}
	if ruleSet.Version != advancedSecurityRuleSetVersion {
		return AdvancedSecurityRuleSet{}, fmt.Errorf("unsupported advanced security rule version: %d", ruleSet.Version)
	}
	if len(ruleSet.Rules) > advancedSecurityMaxRules {
		return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule count cannot exceed %d", advancedSecurityMaxRules)
	}

	seenIDs := make(map[string]struct{}, len(ruleSet.Rules))
	for index := range ruleSet.Rules {
		rule := &ruleSet.Rules[index]
		rule.ID = strings.TrimSpace(rule.ID)
		rule.Name = strings.TrimSpace(rule.Name)
		rule.Category = strings.TrimSpace(rule.Category)
		if rule.ID == "" || len(rule.ID) > advancedSecurityMaxRuleIDLength {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %d has an invalid id", index+1)
		}
		if _, exists := seenIDs[rule.ID]; exists {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule id %q is duplicated", rule.ID)
		}
		seenIDs[rule.ID] = struct{}{}
		if rule.Name == "" {
			rule.Name = rule.ID
		}
		if len(rule.Name) > advancedSecurityMaxRuleNameLength {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %q has a name that is too long", rule.ID)
		}
		if rule.Category == "" {
			rule.Category = "custom"
		}
		if len(rule.Category) > advancedSecurityMaxRuleCategoryLength {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %q has a category that is too long", rule.ID)
		}
		if len(rule.Patterns) == 0 || len(rule.Patterns) > advancedSecurityMaxPatternsPerRule {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %q must contain 1-%d patterns", rule.ID, advancedSecurityMaxPatternsPerRule)
		}

		seenPatterns := make(map[string]struct{}, len(rule.Patterns))
		patterns := make([]string, 0, len(rule.Patterns))
		for _, pattern := range rule.Patterns {
			pattern = strings.TrimSpace(pattern)
			if pattern == "" || len(pattern) > advancedSecurityMaxPatternLength {
				return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %q contains an invalid pattern", rule.ID)
			}
			normalized := strings.ToLower(pattern)
			if _, exists := seenPatterns[normalized]; exists {
				continue
			}
			seenPatterns[normalized] = struct{}{}
			patterns = append(patterns, pattern)
		}
		if len(patterns) == 0 {
			return AdvancedSecurityRuleSet{}, fmt.Errorf("advanced security rule %q must contain a non-empty pattern", rule.ID)
		}
		rule.Patterns = patterns
	}

	return ruleSet, nil
}

func ValidateAdvancedSecurityOption(key string, value string) error {
	switch key {
	case AdvancedSecurityActionOptionKey:
		return validateAdvancedSecurityAction(value)
	case AdvancedSecurityRulesOptionKey:
		_, err := ParseAdvancedSecurityRules(value)
		return err
	}
	return nil
}

func validateAdvancedSecurityAction(value string) error {
	action := strings.ToLower(strings.TrimSpace(value))
	if action != AdvancedSecurityActionBlock && action != AdvancedSecurityActionAudit {
		return errors.New("advanced security action must be block or audit")
	}
	return nil
}

func emptyAdvancedSecurityRuleSet() AdvancedSecurityRuleSet {
	return AdvancedSecurityRuleSet{
		Version: advancedSecurityRuleSetVersion,
		Rules:   []AdvancedSecurityRule{},
	}
}

func cloneAdvancedSecurityRules(rules []AdvancedSecurityRule) []AdvancedSecurityRule {
	cloned := make([]AdvancedSecurityRule, len(rules))
	for index, rule := range rules {
		cloned[index] = rule
		cloned[index].Patterns = append([]string(nil), rule.Patterns...)
	}
	return cloned
}
