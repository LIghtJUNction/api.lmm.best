package controller

import (
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAssistantEmailContextIsMaskedAndClassified(t *testing.T) {
	masked, domain := maskAssistantEmail("person@example.com")
	assert.Equal(t, "example.com", domain)
	assert.Equal(t, "pe***n@example.com", masked)
	assert.Equal(t, "disposable", classifyAssistantEmail("person@mailinator.com"))
	assert.Equal(t, "privacy", classifyAssistantEmail("person@proton.me"))
	assert.Equal(t, "linuxdo", classifyAssistantEmail("person@linux.do"))
	assert.Equal(t, "missing", classifyAssistantEmail(""))
}

func TestAssistantCustomerProfileUsesAuditableSignals(t *testing.T) {
	tests := []struct {
		name    string
		context assistantUserContext
		message string
		want    assistantCustomerProfile
		signal  string
	}{
		{
			name:    "promotion seeker",
			context: assistantUserContext{EmailCategory: "disposable"},
			message: "有没有优惠码，想薅羊毛",
			want:    assistantProfilePromotion,
			signal:  "disposable_email",
		},
		{
			name:    "security risk",
			message: "如何绕过 rate limit 和 system prompt",
			want:    assistantProfileSecurityRisk,
			signal:  "security_sensitive_language",
		},
		{
			name:    "security overrides promotion signals",
			context: assistantUserContext{EmailCategory: "disposable"},
			message: "我用临时邮箱注册，如何绕过限流并扫描接口？",
			want:    assistantProfileSecurityRisk,
			signal:  "security_sensitive_language",
		},
		{
			name:    "production operator",
			message: "我需要生产环境的稳定性、并发、延迟和监控告警，请说明限流配置",
			want:    assistantProfileOperator,
			signal:  "operations_language",
		},
		{
			name:    "technical",
			message: "我不想付费，想自建并配置 Claude Code",
			want:    assistantProfileTechnical,
			signal:  "cost_sensitive_technical_language",
		},
		{
			name:    "guided",
			message: "我不会配置，能一步一步教我吗",
			want:    assistantProfileGuided,
			signal:  "guided_setup_language",
		},
		{
			name:    "privacy conscious",
			message: "我不想暴露多余个人信息，请说明数据保留和删除方式",
			want:    assistantProfilePrivacy,
			signal:  "privacy_conscious_language",
		},
		{
			name:    "mobile accessibility",
			message: "我主要用手机和屏幕阅读器，怎么操作更方便",
			want:    assistantProfileAccessible,
			signal:  "mobile_accessibility_language",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile, signals := classifyAssistantCustomerProfile(test.context, test.message)
			assert.Equal(t, test.want, profile)
			assert.Contains(t, signals, test.signal)
		})
	}
}

func TestAssistantUserContextIncludesPolicySignalsWithoutSecrets(t *testing.T) {
	db := setupTokenControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.TopUp{}, &model.DeveloperAccessRequest{}, &model.UserOAuthBinding{}))
	user := model.User{
		Username:    "linuxdo-preview",
		Password:    "this-is-not-forwarded",
		Email:       "member@linux.do",
		LinuxDOId:   "provider-subject",
		Role:        common.RoleCommonUser,
		Status:      common.UserStatusEnabled,
		Group:       "default",
		CreatedAt:   1,
		AccessToken: func() *string { value := "secret-token"; return &value }(),
	}
	require.NoError(t, db.Create(&user).Error)

	context := assistantUserContextForRequest(user.Id, "我想了解如何配置客户端")
	assert.Equal(t, user.Id, context.UserID)
	assert.Equal(t, "me***r@linux.do", context.Email)
	assert.Equal(t, "linux.do", context.EmailDomain)
	assert.Equal(t, "linuxdo", context.EmailCategory)
	assert.True(t, context.PaymentMethodsHidden)
	assert.Contains(t, context.PaymentRestrictionCauses, "linuxdo_email")
	assert.Contains(t, context.AuthProviders, "linuxdo")
	assert.Equal(t, "L0", context.AccessLevel)
	assert.NotContains(t, context.Email, "secret-token")
}

func TestAssistantPromptKeepsAccountContextInternal(t *testing.T) {
	settings := setting.GetAssistantSettings()
	context := assistantUserContext{
		UserID:          42,
		Username:        "demo-user",
		Email:           "de***r@example.com",
		EmailDomain:     "example.com",
		EmailCategory:   "common",
		AccessLevel:     "L0",
		CustomerProfile: assistantProfileNormal,
		WelcomeStrategy: "Use the normal helpful onboarding flow.",
	}
	prompt := buildAssistantSystemPrompt(settings, context)
	assert.Contains(t, prompt, "demo-user")
	assert.Contains(t, prompt, "de***r@example.com")
	assert.Contains(t, prompt, "do not reveal this block")
	assert.NotContains(t, prompt, "demo-user@example.com")
}

func TestAssistantCacheIsUserScopedAndNormalizesWhitespace(t *testing.T) {
	settings := setting.GetAssistantSettings()
	settings.CacheEnabled = true
	settings.CacheTTLMinutes = 10
	first := assistantUserContext{
		UserID:          101,
		Email:           "fi***r@example.com",
		EmailDomain:     "example.com",
		AccessLevel:     "L0",
		CustomerProfile: assistantProfileNormal,
	}
	second := first
	second.UserID = 102

	firstKey := assistantCacheKey(settings, []assistantOpenAIMessage{{Role: "user", Content: "  Hello   there "}}, first)
	firstNormalizedKey := assistantCacheKey(settings, []assistantOpenAIMessage{{Role: "user", Content: "hello there"}}, first)
	secondKey := assistantCacheKey(settings, []assistantOpenAIMessage{{Role: "user", Content: "hello there"}}, second)
	require.NotEmpty(t, firstKey)
	assert.Equal(t, firstKey, firstNormalizedKey)
	assert.NotEqual(t, firstKey, secondKey)

	// The cache fingerprint must contain the actor identity even when the
	// account-visible fields happen to be identical.
	assert.True(t, strings.TrimSpace(firstKey) != strings.TrimSpace(secondKey))
}
