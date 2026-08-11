package controller

import (
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
)

const (
	paymentMethodUnlockAfterDaysKey  = "unlock_after_days"
	paymentMethodAudienceModeKey     = "audience_mode"
	paymentMethodAudienceMatchKey    = "audience_match"
	paymentMethodAudienceEmailKey    = "audience_email_contains"
	paymentMethodAudienceOAuthKey    = "audience_oauth_provider"
	paymentMethodAudienceScoreMinKey = "audience_linuxdo_score_min"
	paymentMethodAudienceScoreMaxKey = "audience_linuxdo_score_max"
	secondsPerDay                    = int64(24 * time.Hour / time.Second)
)

type paymentMethodAudienceRule struct {
	Mode          string
	Match         string
	EmailContains string
	OAuthProvider string
	ScoreMin      *float64
	ScoreMax      *float64
}

// configuredPaymentMethodUnlockDays returns the strongest unlock delay for a
// payment type. Payment requests identify a method by type, so duplicate
// catalog entries with the same type cannot safely carry different policies.
func configuredPaymentMethodUnlockDays(paymentType string) (int64, error) {
	paymentType = strings.TrimSpace(paymentType)
	var unlockAfterDays int64

	for _, method := range operation_setting.PayMethods {
		if strings.TrimSpace(method["type"]) != paymentType {
			continue
		}

		rawDays, configured := method[paymentMethodUnlockAfterDaysKey]
		rawDays = strings.TrimSpace(rawDays)
		if !configured || rawDays == "" {
			continue
		}

		days, err := strconv.ParseInt(rawDays, 10, 64)
		if err != nil || days < 0 {
			return 0, fmt.Errorf("payment method %q has invalid %s", paymentType, paymentMethodUnlockAfterDaysKey)
		}
		if days > unlockAfterDays {
			unlockAfterDays = days
		}
	}

	return unlockAfterDays, nil
}

func paymentMethodUnlockedForUser(user *model.User, paymentType string, now time.Time) (bool, int64, error) {
	unlockAfterDays, err := configuredPaymentMethodUnlockDays(paymentType)
	if err != nil {
		return false, 0, err
	}
	if unlockAfterDays == 0 {
		return true, 0, nil
	}
	if user == nil || user.CreatedAt <= 0 {
		return false, 0, fmt.Errorf("user registration time is unavailable")
	}
	if unlockAfterDays > (math.MaxInt64-user.CreatedAt)/secondsPerDay {
		return false, 0, fmt.Errorf("payment method %q unlock time overflows", paymentType)
	}

	unlockAt := user.CreatedAt + unlockAfterDays*secondsPerDay
	return now.Unix() >= unlockAt, unlockAt, nil
}

func parseAudienceScore(raw string) (*float64, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
		return nil, fmt.Errorf("invalid LinuxDO score %q", raw)
	}
	return &value, nil
}

func parsePaymentMethodAudienceRule(method map[string]string) (paymentMethodAudienceRule, bool, error) {
	mode := strings.ToLower(strings.TrimSpace(method[paymentMethodAudienceModeKey]))
	if mode == "" || mode == "legacy" {
		return paymentMethodAudienceRule{Mode: "legacy"}, false, nil
	}
	if mode != "all" && mode != "include" && mode != "exclude" {
		return paymentMethodAudienceRule{}, true, fmt.Errorf("invalid payment audience mode %q", mode)
	}

	match := strings.ToLower(strings.TrimSpace(method[paymentMethodAudienceMatchKey]))
	if match == "" {
		match = "any"
	}
	if match != "any" && match != "all" {
		return paymentMethodAudienceRule{}, true, fmt.Errorf("invalid payment audience match mode %q", match)
	}

	scoreMin, err := parseAudienceScore(method[paymentMethodAudienceScoreMinKey])
	if err != nil {
		return paymentMethodAudienceRule{}, true, err
	}
	scoreMax, err := parseAudienceScore(method[paymentMethodAudienceScoreMaxKey])
	if err != nil {
		return paymentMethodAudienceRule{}, true, err
	}
	if scoreMin != nil && scoreMax != nil && *scoreMin > *scoreMax {
		return paymentMethodAudienceRule{}, true, fmt.Errorf("LinuxDO score minimum exceeds maximum")
	}

	rule := paymentMethodAudienceRule{
		Mode:          mode,
		Match:         match,
		EmailContains: strings.ToLower(strings.TrimSpace(method[paymentMethodAudienceEmailKey])),
		OAuthProvider: strings.ToLower(strings.TrimSpace(method[paymentMethodAudienceOAuthKey])),
		ScoreMin:      scoreMin,
		ScoreMax:      scoreMax,
	}
	if rule.OAuthProvider != "" {
		normalizedProvider := strings.ReplaceAll(rule.OAuthProvider, ".", "")
		switch normalizedProvider {
		case "linuxdo", "github", "discord", "oidc", "wechat", "telegram":
			rule.OAuthProvider = normalizedProvider
		default:
			return paymentMethodAudienceRule{}, true, fmt.Errorf("unsupported OAuth provider %q", rule.OAuthProvider)
		}
	}
	if mode != "all" && rule.EmailContains == "" && rule.OAuthProvider == "" && scoreMin == nil && scoreMax == nil {
		return paymentMethodAudienceRule{}, true, fmt.Errorf("payment audience rule has no conditions")
	}
	return rule, true, nil
}

func userHasOAuthProvider(user *model.User, provider string) bool {
	if user == nil {
		return false
	}
	switch strings.ReplaceAll(provider, ".", "") {
	case "linuxdo":
		return strings.TrimSpace(user.LinuxDOId) != ""
	case "github":
		return strings.TrimSpace(user.GitHubId) != ""
	case "discord":
		return strings.TrimSpace(user.DiscordId) != ""
	case "oidc":
		return strings.TrimSpace(user.OidcId) != ""
	case "wechat":
		return strings.TrimSpace(user.WeChatId) != ""
	case "telegram":
		return strings.TrimSpace(user.TelegramId) != ""
	default:
		return false
	}
}

func paymentMethodAudienceRuleMatches(user *model.User, rule paymentMethodAudienceRule) bool {
	if user == nil {
		return false
	}
	conditions := make([]bool, 0, 3)
	if rule.EmailContains != "" {
		conditions = append(conditions, strings.Contains(strings.ToLower(strings.TrimSpace(user.Email)), rule.EmailContains))
	}
	if rule.OAuthProvider != "" {
		conditions = append(conditions, userHasOAuthProvider(user, rule.OAuthProvider))
	}
	if rule.ScoreMin != nil || rule.ScoreMax != nil {
		score, known := model.LinuxDOGamificationScoreForAudience(user)
		matches := known
		if matches && rule.ScoreMin != nil {
			matches = score >= *rule.ScoreMin
		}
		if matches && rule.ScoreMax != nil {
			matches = score <= *rule.ScoreMax
		}
		conditions = append(conditions, matches)
	}

	if rule.Match == "all" {
		for _, condition := range conditions {
			if !condition {
				return false
			}
		}
		return true
	}
	for _, condition := range conditions {
		if condition {
			return true
		}
	}
	return false
}

// paymentMethodVisibleForUser evaluates explicit per-method rules. If a
// method has no rule, the existing account payment marker remains authoritative
// so upgrades do not silently reopen payment for previously restricted users.
func paymentMethodVisibleForUser(user *model.User, paymentType string) (bool, error) {
	hasExplicitRule := false
	for _, method := range operation_setting.PayMethods {
		if strings.TrimSpace(method["type"]) != strings.TrimSpace(paymentType) {
			continue
		}
		rule, explicit, err := parsePaymentMethodAudienceRule(method)
		if err != nil {
			return false, err
		}
		if !explicit {
			continue
		}
		hasExplicitRule = true
		if rule.Mode == "all" {
			continue
		}
		matches := paymentMethodAudienceRuleMatches(user, rule)
		if (rule.Mode == "include" && !matches) || (rule.Mode == "exclude" && matches) {
			return false, nil
		}
	}
	if hasExplicitRule {
		return true, nil
	}
	return !model.IsPaymentRestricted(user), nil
}

func paymentMethodAvailableForUser(user *model.User, paymentType string, now time.Time) (bool, int64, error) {
	unlocked, unlockAt, err := paymentMethodUnlockedForUser(user, paymentType, now)
	if err != nil || !unlocked {
		return false, unlockAt, err
	}
	visible, err := paymentMethodVisibleForUser(user, paymentType)
	if err != nil || !visible {
		return false, unlockAt, err
	}
	return true, unlockAt, nil
}

func isPaymentMethodAvailableForUser(user *model.User, paymentType string, now time.Time) bool {
	available, _, err := paymentMethodAvailableForUser(user, paymentType, now)
	return err == nil && available
}

// requirePaymentMethodAvailable is the server-side enforcement point shared by
// quote and checkout endpoints. Catalog filtering alone is not authoritative.
func requirePaymentMethodAvailable(c *gin.Context, paymentType string) bool {
	var user *model.User
	if cached, ok := c.Get("payment_user"); ok {
		user, _ = cached.(*model.User)
	}
	var err error
	if user == nil {
		user, err = model.GetUserById(c.GetInt("id"), false)
	}
	if err != nil || user == nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "获取用户信息失败"})
		return false
	}

	available, unlockAt, err := paymentMethodAvailableForUser(user, paymentType, time.Now())
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "支付方式配置无效"})
		return false
	}
	if !available {
		message := "该支付方式不可用"
		if unlockAt > time.Now().Unix() {
			message = "该支付方式尚未解锁"
		}
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": message})
		return false
	}
	return true
}
