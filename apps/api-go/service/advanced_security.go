package service

import (
	"strings"

	"github.com/QuantumNous/new-api/setting"
)

type AdvancedSecurityMatch struct {
	RuleID   string
	RuleName string
	Category string
	Pattern  string
}

// CheckAdvancedSecurityText applies the configured literal rule library with
// the shared Aho-Corasick matcher. It is intentionally separate from the
// legacy sensitive-word check so operators can tune either mechanism without
// changing the other one's behavior.
func CheckAdvancedSecurityText(text string) []AdvancedSecurityMatch {
	if !setting.ShouldCheckAdvancedSecurityPrompt() || strings.TrimSpace(text) == "" {
		return nil
	}

	settings := setting.GetAdvancedSecuritySettings()
	patterns := make([]string, 0)
	seenPatterns := make(map[string]struct{})
	for _, rule := range settings.RuleSet.Rules {
		if !rule.Enabled {
			continue
		}
		for _, pattern := range rule.Patterns {
			normalized := strings.ToLower(strings.TrimSpace(pattern))
			if normalized == "" {
				continue
			}
			if _, exists := seenPatterns[normalized]; !exists {
				patterns = append(patterns, normalized)
				seenPatterns[normalized] = struct{}{}
			}
		}
	}
	if len(patterns) == 0 {
		return nil
	}

	_, words := AcSearch(strings.ToLower(text), patterns, false)
	if len(words) == 0 {
		return nil
	}

	matchedPatterns := make(map[string]struct{}, len(words))
	for _, word := range words {
		matchedPatterns[strings.ToLower(strings.TrimSpace(word))] = struct{}{}
	}

	matches := make([]AdvancedSecurityMatch, 0)
	for _, rule := range settings.RuleSet.Rules {
		if !rule.Enabled {
			continue
		}
		for _, pattern := range rule.Patterns {
			normalized := strings.ToLower(strings.TrimSpace(pattern))
			if _, matched := matchedPatterns[normalized]; !matched {
				continue
			}
			matches = append(matches, AdvancedSecurityMatch{
				RuleID:   rule.ID,
				RuleName: rule.Name,
				Category: rule.Category,
				Pattern:  normalized,
			})
			break
		}
	}
	return matches
}
