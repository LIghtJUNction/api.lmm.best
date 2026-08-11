package model

import (
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/QuantumNous/new-api/common"
	"gorm.io/gorm"
)

const (
	AssistantLeadSourceChat    = "chat"
	AssistantLeadSourceHandoff = "handoff"

	AssistantLeadStatusObserved = "observed"
	AssistantLeadStatusPending  = "pending"
	AssistantLeadStatusResolved = "resolved"

	AssistantIntentOnboarding   = "onboarding"
	AssistantIntentPlanPurchase = "plan_purchase"
	AssistantIntentAPIKey       = "api_key"
	AssistantIntentClientSetup  = "client_setup"
	AssistantIntentCost         = "cost"
	AssistantIntentBounty       = "bounty"
	AssistantIntentUsage        = "usage"
	AssistantIntentModels       = "models"
	AssistantIntentInvitation   = "invitation"
	AssistantIntentHumanSupport = "human_support"
	AssistantIntentOther        = "other"

	minAssistantHandoffRunes   = 5
	maxAssistantHandoffRunes   = 2000
	maxAssistantAdminNoteRunes = 2000
)

var (
	ErrAssistantHandoffMessageRequired = errors.New("support message is required")
	ErrAssistantHandoffMessageTooShort = errors.New("support message must contain at least 5 characters")
	ErrAssistantHandoffMessageTooLong  = errors.New("support message must be at most 2000 characters")
	ErrAssistantLeadNotFound           = errors.New("assistant support request not found")
	ErrAssistantLeadAlreadyResolved    = errors.New("assistant support request is already resolved")
	ErrAssistantLeadStatus             = errors.New("assistant support request status is invalid")
	ErrAssistantAdminNoteTooLong       = errors.New("assistant support note must be at most 2000 characters")

	assistantAPIKeyPattern = regexp.MustCompile(`(?i)\bsk-[a-z0-9._-]{6,}\b`)
	assistantBearerPattern = regexp.MustCompile(`(?i)\bbearer\s+[a-z0-9._~+/-]{6,}=*`)
	assistantSecretPattern = regexp.MustCompile(`(?i)(password|passwd|api[ _-]?key|access[ _-]?token|密码|密钥|令牌)\s*[:=：]\s*\S+`)
)

// AssistantLead stores privacy-minimized intent signals and explicit support
// handoffs. Chat rows contain only the classified intent; raw chat text is not
// persisted. A handoff stores the user's explicitly submitted, redacted note.
type AssistantLead struct {
	Id          int    `json:"id" gorm:"primaryKey"`
	UserId      int    `json:"user_id" gorm:"not null;index"`
	Source      string `json:"source" gorm:"type:varchar(20);not null;index"`
	Intent      string `json:"intent" gorm:"type:varchar(40);not null;index"`
	Message     string `json:"message" gorm:"type:text"`
	Status      string `json:"status" gorm:"type:varchar(20);not null;index"`
	AdminUserId int    `json:"admin_user_id" gorm:"index"`
	AdminNote   string `json:"admin_note" gorm:"type:text"`
	CreatedAt   int64  `json:"created_at" gorm:"not null;index"`
	ResolvedAt  int64  `json:"resolved_at" gorm:"not null;default:0"`
}

func (AssistantLead) TableName() string { return "assistant_leads" }

type AssistantLeadView struct {
	AssistantLead
	Username string `json:"username"`
	Email    string `json:"email"`
}

type AssistantIntentSummary struct {
	Intent string `json:"intent"`
	Count  int64  `json:"count"`
}

// AssistantProfileEvent is intentionally aggregate-only. It has no user ID,
// email, raw message, or account metadata; it exists solely to help an
// administrator compare onboarding strategies over time.
type AssistantProfileEvent struct {
	Id        int    `json:"id" gorm:"primaryKey"`
	Profile   string `json:"profile" gorm:"type:varchar(64);not null;index"`
	CreatedAt int64  `json:"created_at" gorm:"not null;index"`
}

func (AssistantProfileEvent) TableName() string { return "assistant_profile_events" }

type AssistantProfileSummary struct {
	Profile string `json:"profile"`
	Count   int64  `json:"count"`
}

var assistantProfileNames = map[string]struct{}{
	"unknown":                  {},
	"technical_cost_sensitive": {},
	"guided_buyer":             {},
	"promotion_seeker":         {},
	"security_risk":            {},
	"production_operator":      {},
	"privacy_conscious":        {},
	"mobile_accessibility":     {},
	"normal_user":              {},
}

func assistantMessageContains(message string, terms ...string) bool {
	for _, term := range terms {
		if strings.Contains(message, term) {
			return true
		}
	}
	return false
}

// ClassifyAssistantIntent intentionally uses a deterministic, auditable
// keyword classifier. It is sufficient for product analytics and cannot turn
// model output into an account action.
func ClassifyAssistantIntent(message string) string {
	normalized := strings.ToLower(strings.TrimSpace(message))
	switch {
	case assistantMessageContains(normalized,
		"新手", "入门", "审核", "解锁", "l0", "l1", "onboarding", "review", "approval", "getting started"):
		return AssistantIntentOnboarding
	case assistantMessageContains(normalized,
		"人工", "客服", "管理员", "工单", "human", "support", "administrator", "agent"):
		return AssistantIntentHumanSupport
	case assistantMessageContains(normalized,
		"成本", "费用", "计费", "消耗", "cost", "estimate", "billing", "token price"):
		return AssistantIntentCost
	case assistantMessageContains(normalized,
		"历史调用", "调用数据", "调用统计", "用量统计", "使用统计", "调用记录", "usage", "usage logs", "request history", "statistics"):
		return AssistantIntentUsage
	case assistantMessageContains(normalized,
		"有哪些模型", "模型列表", "可用模型", "模型清单", "available models", "model list", "model ids"):
		return AssistantIntentModels
	case assistantMessageContains(normalized,
		"邀请奖励", "邀请码", "邀请链接", "邀请用户", "affiliate", "referral", "invite reward"):
		return AssistantIntentInvitation
	case assistantMessageContains(normalized,
		"claude code", "cc switch", "cc-switch", "chatgpt", "windows", "linux", "macos", "mac os", "桌面版", "安装", "配置客户端"):
		return AssistantIntentClientSetup
	case assistantMessageContains(normalized,
		"api key", "api-key", "apikey", "base url", "base_url", "model id", "模型 id", "模型id", "密钥", "令牌", "token", "创建 key", "创建key", "create key", "create a key", "create my key"):
		return AssistantIntentAPIKey
	case assistantMessageContains(normalized,
		"开源", "悬赏", "挑战", "小费", "bounty", "tip", "challenge", "任务发布"):
		return AssistantIntentBounty
	case assistantMessageContains(normalized,
		"套餐", "购买", "划算", "优惠", "折扣", "订阅", "plan", "purchase", "discount", "best value"):
		return AssistantIntentPlanPurchase
	default:
		return AssistantIntentOther
	}
}

func redactAssistantHandoffMessage(message string) string {
	message = assistantAPIKeyPattern.ReplaceAllString(message, "[REDACTED_API_KEY]")
	message = assistantBearerPattern.ReplaceAllString(message, "Bearer [REDACTED_TOKEN]")
	return assistantSecretPattern.ReplaceAllString(message, "$1: [REDACTED]")
}

func normalizeAssistantHandoffMessage(message string) (string, error) {
	message = strings.TrimSpace(message)
	if message == "" {
		return "", ErrAssistantHandoffMessageRequired
	}
	if utf8.RuneCountInString(message) < minAssistantHandoffRunes {
		return "", ErrAssistantHandoffMessageTooShort
	}
	if utf8.RuneCountInString(message) > maxAssistantHandoffRunes {
		return "", ErrAssistantHandoffMessageTooLong
	}
	return redactAssistantHandoffMessage(message), nil
}

func normalizeAssistantAdminNote(note string) (string, error) {
	note = strings.TrimSpace(note)
	if utf8.RuneCountInString(note) > maxAssistantAdminNoteRunes {
		return "", ErrAssistantAdminNoteTooLong
	}
	return note, nil
}

// RecordAssistantIntent persists only a category, never the raw chat message.
func RecordAssistantIntent(userID int, message string) error {
	if userID <= 0 {
		return gorm.ErrInvalidData
	}
	return DB.Create(&AssistantLead{
		UserId:    userID,
		Source:    AssistantLeadSourceChat,
		Intent:    ClassifyAssistantIntent(message),
		Status:    AssistantLeadStatusObserved,
		CreatedAt: common.GetTimestamp(),
	}).Error
}

func SubmitAssistantHandoff(userID int, message string) (*AssistantLead, error) {
	if userID <= 0 {
		return nil, gorm.ErrInvalidData
	}
	normalized, err := normalizeAssistantHandoffMessage(message)
	if err != nil {
		return nil, err
	}

	var lead AssistantLead
	err = DB.Transaction(func(tx *gorm.DB) error {
		var user User
		if err := lockForUpdate(tx).Select("id").First(&user, userID).Error; err != nil {
			return err
		}
		findErr := tx.Where("user_id = ? AND source = ? AND status = ?", userID, AssistantLeadSourceHandoff, AssistantLeadStatusPending).
			Order("id DESC").First(&lead).Error
		if findErr == nil {
			return nil
		}
		if !errors.Is(findErr, gorm.ErrRecordNotFound) {
			return findErr
		}
		lead = AssistantLead{
			UserId:    userID,
			Source:    AssistantLeadSourceHandoff,
			Intent:    AssistantIntentHumanSupport,
			Message:   normalized,
			Status:    AssistantLeadStatusPending,
			CreatedAt: common.GetTimestamp(),
		}
		return tx.Create(&lead).Error
	})
	if err != nil {
		return nil, err
	}
	return &lead, nil
}

func GetLatestAssistantHandoff(userID int) (*AssistantLead, error) {
	if userID <= 0 {
		return nil, gorm.ErrInvalidData
	}
	var lead AssistantLead
	err := DB.Where("user_id = ? AND source = ?", userID, AssistantLeadSourceHandoff).
		Order("id DESC").First(&lead).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &lead, nil
}

func ListAssistantHandoffs(status string, limit int) ([]AssistantLeadView, error) {
	status = strings.TrimSpace(status)
	if status == "" {
		status = AssistantLeadStatusPending
	}
	if status != AssistantLeadStatusPending && status != AssistantLeadStatusResolved {
		return nil, ErrAssistantLeadStatus
	}
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	var leads []AssistantLeadView
	err := DB.Table("assistant_leads AS lead").
		Select("lead.*, users.username, users.email").
		Joins("JOIN users ON users.id = lead.user_id").
		Where("lead.source = ? AND lead.status = ?", AssistantLeadSourceHandoff, status).
		Order("lead.id DESC").Limit(limit).Find(&leads).Error
	return leads, err
}

func ListAssistantIntentSummary(since int64) ([]AssistantIntentSummary, error) {
	query := DB.Model(&AssistantLead{}).
		Select("intent, COUNT(*) AS count").
		Group("intent").Order("count DESC, intent ASC")
	if since > 0 {
		query = query.Where("created_at >= ?", since)
	}
	var summary []AssistantIntentSummary
	if err := query.Scan(&summary).Error; err != nil {
		return nil, err
	}
	return summary, nil
}

func RecordAssistantProfile(profile string) error {
	profile = strings.TrimSpace(profile)
	if _, ok := assistantProfileNames[profile]; !ok {
		return errors.New("assistant profile is invalid")
	}
	return DB.Create(&AssistantProfileEvent{
		Profile:   profile,
		CreatedAt: common.GetTimestamp(),
	}).Error
}

func ListAssistantProfileSummary(since int64) ([]AssistantProfileSummary, error) {
	query := DB.Model(&AssistantProfileEvent{}).
		Select("profile, COUNT(*) AS count").
		Group("profile").Order("count DESC, profile ASC")
	if since > 0 {
		query = query.Where("created_at >= ?", since)
	}
	var summary []AssistantProfileSummary
	if err := query.Scan(&summary).Error; err != nil {
		return nil, err
	}
	return summary, nil
}

func ResolveAssistantHandoff(adminUserID int, leadID int, note string) (*AssistantLead, error) {
	if adminUserID <= 0 || leadID <= 0 {
		return nil, gorm.ErrInvalidData
	}
	normalizedNote, err := normalizeAssistantAdminNote(note)
	if err != nil {
		return nil, err
	}
	var lead AssistantLead
	err = DB.Transaction(func(tx *gorm.DB) error {
		if err := lockForUpdate(tx).Where("id = ? AND source = ?", leadID, AssistantLeadSourceHandoff).First(&lead).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrAssistantLeadNotFound
			}
			return err
		}
		if lead.Status != AssistantLeadStatusPending {
			return ErrAssistantLeadAlreadyResolved
		}
		now := common.GetTimestamp()
		if err := tx.Model(&lead).Updates(map[string]any{
			"status":        AssistantLeadStatusResolved,
			"admin_user_id": adminUserID,
			"admin_note":    normalizedNote,
			"resolved_at":   now,
		}).Error; err != nil {
			return err
		}
		lead.Status = AssistantLeadStatusResolved
		lead.AdminUserId = adminUserID
		lead.AdminNote = normalizedNote
		lead.ResolvedAt = now
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &lead, nil
}
