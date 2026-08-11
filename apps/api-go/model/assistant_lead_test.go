package model

import (
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func setupAssistantLeadTestDB(t *testing.T) *User {
	t.Helper()
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&AssistantLead{}, &AssistantProfileEvent{}))
	user := &User{
		Username: "assistant-lead-user",
		Password: "password",
		Email:    "assistant@example.com",
		Role:     common.RoleCommonUser,
		Status:   common.UserStatusEnabled,
	}
	require.NoError(t, db.Create(user).Error)
	return user
}

func TestClassifyAssistantIntent(t *testing.T) {
	tests := map[string]string{
		"请转人工客服":                             AssistantIntentHumanSupport,
		"How do I create an API key?":        AssistantIntentAPIKey,
		"Base URL 和模型 ID 是什么":                AssistantIntentAPIKey,
		"Windows 安装 Claude Code 和 CC Switch": AssistantIntentClientSetup,
		"macOS 怎样配置 cc-switch":               AssistantIntentClientSetup,
		"怎样把 Base URL 配置进 cc-switch":         AssistantIntentClientSetup,
		"开源挑战完成后怎么赠小费":                       AssistantIntentBounty,
		"帮我计算 token 成本":                      AssistantIntentCost,
		"哪个套餐最划算，有优惠吗":                       AssistantIntentPlanPurchase,
		"L0 审核多久能到 L1":                       AssistantIntentOnboarding,
		"请管理员帮我审核 L1":                        AssistantIntentOnboarding,
		"hello":                              AssistantIntentOther,
	}
	for message, expected := range tests {
		assert.Equal(t, expected, ClassifyAssistantIntent(message), message)
	}
}

func TestRecordAssistantIntentDoesNotPersistChatMessage(t *testing.T) {
	user := setupAssistantLeadTestDB(t)
	require.NoError(t, RecordAssistantIntent(user.Id, "我的 API key 是 sk-super-secret-123"))

	var lead AssistantLead
	require.NoError(t, DB.First(&lead).Error)
	assert.Equal(t, AssistantLeadSourceChat, lead.Source)
	assert.Equal(t, AssistantIntentAPIKey, lead.Intent)
	assert.Empty(t, lead.Message)
}

func TestAssistantHandoffRedactsSecretsAndIsIdempotent(t *testing.T) {
	user := setupAssistantLeadTestDB(t)
	lead, err := SubmitAssistantHandoff(user.Id, "登录失败，password: hunter2，key=sk-secret-token-123")
	require.NoError(t, err)
	assert.NotContains(t, lead.Message, "hunter2")
	assert.NotContains(t, lead.Message, "sk-secret-token-123")
	assert.Contains(t, lead.Message, "[REDACTED]")

	repeated, err := SubmitAssistantHandoff(user.Id, "another message")
	require.NoError(t, err)
	assert.Equal(t, lead.Id, repeated.Id)

	pending, err := ListAssistantHandoffs(AssistantLeadStatusPending, 10)
	require.NoError(t, err)
	require.Len(t, pending, 1)
	assert.Equal(t, user.Username, pending[0].Username)

	resolved, err := ResolveAssistantHandoff(99, lead.Id, "emailed user")
	require.NoError(t, err)
	assert.Equal(t, AssistantLeadStatusResolved, resolved.Status)
	assert.Equal(t, 99, resolved.AdminUserId)
	assert.Positive(t, resolved.ResolvedAt)

	_, err = ResolveAssistantHandoff(99, lead.Id, "again")
	assert.ErrorIs(t, err, ErrAssistantLeadAlreadyResolved)
}

func TestAssistantHandoffValidationAndIntentSummary(t *testing.T) {
	user := setupAssistantLeadTestDB(t)
	_, err := SubmitAssistantHandoff(user.Id, "")
	assert.ErrorIs(t, err, ErrAssistantHandoffMessageRequired)
	_, err = SubmitAssistantHandoff(user.Id, "四个字")
	assert.ErrorIs(t, err, ErrAssistantHandoffMessageTooShort)
	_, err = SubmitAssistantHandoff(user.Id, strings.Repeat("问", maxAssistantHandoffRunes+1))
	assert.ErrorIs(t, err, ErrAssistantHandoffMessageTooLong)

	require.NoError(t, RecordAssistantIntent(user.Id, "哪个套餐最划算"))
	require.NoError(t, RecordAssistantIntent(user.Id, "有没有优惠套餐"))
	require.NoError(t, RecordAssistantIntent(user.Id, "如何创建 API key"))
	summary, err := ListAssistantIntentSummary(0)
	require.NoError(t, err)
	require.Len(t, summary, 2)
	assert.Equal(t, AssistantIntentPlanPurchase, summary[0].Intent)
	assert.EqualValues(t, 2, summary[0].Count)
}

func TestAssistantProfileSummaryIsAggregateOnly(t *testing.T) {
	_ = setupAssistantLeadTestDB(t)
	require.NoError(t, RecordAssistantProfile("guided_buyer"))
	require.NoError(t, RecordAssistantProfile("guided_buyer"))
	require.NoError(t, RecordAssistantProfile("normal_user"))

	summary, err := ListAssistantProfileSummary(0)
	require.NoError(t, err)
	require.Len(t, summary, 2)
	assert.Equal(t, "guided_buyer", summary[0].Profile)
	assert.EqualValues(t, 2, summary[0].Count)
	assert.Equal(t, "normal_user", summary[1].Profile)
	assert.EqualValues(t, 1, summary[1].Count)

	var events []AssistantProfileEvent
	require.NoError(t, DB.Find(&events).Error)
	require.Len(t, events, 3)
	assert.NotContains(t, events[0].Profile, "@")
	assert.Error(t, RecordAssistantProfile("user@example.com"))
}
