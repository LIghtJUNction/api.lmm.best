package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	relaycommon "github.com/QuantumNous/new-api/relay/common"
	"github.com/QuantumNous/new-api/setting"
	"github.com/gin-gonic/gin"
)

type AdvancedSecurityMatch struct {
	RuleID      string
	RuleName    string
	Category    string
	Layer       string
	Severity    string
	Source      string
	RuleVersion string
	Pattern     string
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
				RuleID:      rule.ID,
				RuleName:    rule.Name,
				Category:    rule.Category,
				Layer:       rule.Layer,
				Severity:    rule.Severity,
				Source:      rule.Source,
				RuleVersion: rule.Version,
				Pattern:     normalized,
			})
			break
		}
	}
	return matches
}

// RecordAdvancedSecurityDetection persists one row per matched rule. The
// method is deliberately best-effort: a database write failure must not turn
// an already evaluated block/audit decision into an upstream request failure.
func RecordAdvancedSecurityDetection(c *gin.Context, relayInfo *relaycommon.RelayInfo, input string, matches []AdvancedSecurityMatch, decision string) {
	if len(matches) == 0 {
		return
	}

	requestID := ""
	username := ""
	endpoint := ""
	userID := 0
	if c != nil {
		requestID = c.GetString(common.RequestIdKey)
		username = c.GetString("username")
		userID = c.GetInt("id")
		if c.Request != nil && c.Request.URL != nil {
			endpoint = c.Request.URL.Path
		}
	}
	if relayInfo != nil {
		if relayInfo.RequestId != "" {
			requestID = relayInfo.RequestId
		}
		if relayInfo.UserId > 0 {
			userID = relayInfo.UserId
		}
	}
	if requestID == "" {
		requestID = common.NewRequestId()
	}

	params := model.AdvancedSecurityEventParams{
		CreatedAt:   common.GetTimestamp(),
		RequestID:   requestID,
		UserID:      userID,
		Username:    username,
		Decision:    decision,
		InputDigest: securityDigest(input),
	}
	if relayInfo != nil {
		params.TokenID = relayInfo.TokenId
		params.ModelName = relayInfo.OriginModelName
		params.Group = relayInfo.UsingGroup
		if relayInfo.ChannelMeta != nil {
			params.ChannelID = relayInfo.ChannelId
		}
	}
	params.Endpoint = endpoint
	params.Matches = make([]model.AdvancedSecurityEventMatch, 0, len(matches))
	for _, match := range matches {
		params.Matches = append(params.Matches, model.AdvancedSecurityEventMatch{
			RuleID:        match.RuleID,
			RuleName:      match.RuleName,
			Category:      match.Category,
			Layer:         match.Layer,
			Severity:      match.Severity,
			Source:        match.Source,
			RuleVersion:   match.RuleVersion,
			PatternDigest: securityDigest(match.Pattern),
		})
	}
	if err := model.RecordAdvancedSecurityEvents(requestContext(c), params); err != nil {
		common.SysError("failed to record advanced security detection: " + err.Error())
	}
}

func requestContext(c *gin.Context) context.Context {
	if c != nil && c.Request != nil {
		return c.Request.Context()
	}
	return context.Background()
}

func securityDigest(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}
