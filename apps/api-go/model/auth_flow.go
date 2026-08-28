package model

import (
	cryptorand "crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeOAuth = "oauth"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeTwoFALogin = "2fa_login"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposePasskeyLogin = "passkey_login"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposePasskeyRegister = "passkey_register"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposePasskeyStepUp = "passkey_step_up"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeWeChatLogin = "wechat_login"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeTelegramLogin = "telegram_login"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeTelegramBind = "telegram_bind"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeTelegramAssertion = "telegram_assertion"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeAssistantL1 = "assistant_l1_recommendation"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeAssistantAdmin = "assistant_admin_change"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeAssistantKey = "assistant_key_creation"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeAssistantDrawing = "assistant_drawing_generation"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowPurposeAssistantHandoff = "assistant_handoff"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowIntentLogin = "login"
	// pi-lens-ignore: go-hardcoded-secrets
	AuthFlowIntentBind              = "bind"
	AuthFlowTokenBytes              = 32
	AuthFlowDefaultCleanupRetention = 24 * time.Hour
)

var (
	ErrAuthFlowInvalid  = errors.New("auth flow is invalid")
	ErrAuthFlowExpired  = errors.New("auth flow has expired")
	ErrAuthFlowConsumed = errors.New("auth flow has already been consumed")
)

// AuthFlow stores one-time, short-lived state for authentication ceremonies.
// TokenHash is an HMAC of the opaque token; the token itself is never persisted.
type AuthFlow struct {
	Id         int64      `json:"id" gorm:"primaryKey"`
	TokenHash  string     `json:"-" gorm:"type:char(64);not null;uniqueIndex"`
	Purpose    string     `json:"purpose" gorm:"type:varchar(32);not null;index:idx_auth_flow_purpose_expiry"`
	Provider   string     `json:"provider,omitempty" gorm:"type:varchar(64)"`
	Intent     string     `json:"intent,omitempty" gorm:"type:varchar(16)"`
	UserId     int        `json:"user_id,omitempty" gorm:"index"`
	SessionId  string     `json:"session_id,omitempty" gorm:"type:varchar(64);index"`
	Payload    string     `json:"-" gorm:"type:text"`
	CreatedAt  time.Time  `json:"created_at"`
	ExpiresAt  time.Time  `json:"expires_at" gorm:"not null;index:idx_auth_flow_purpose_expiry"`
	ConsumedAt *time.Time `json:"consumed_at,omitempty" gorm:"index"`
}

func (AuthFlow) TableName() string {
	return "auth_flows"
}

type AuthFlowCreate struct {
	Purpose   string
	Provider  string
	Intent    string
	UserId    int
	SessionId string
	Payload   string
	ExpiresAt time.Time
}

type AuthFlowMatch struct {
	Purpose   string
	Provider  string
	Intent    string
	UserId    int
	SessionId string
}

func applyAuthFlowMatch(query *gorm.DB, token string, match AuthFlowMatch) *gorm.DB {
	query = query.Where("token_hash = ? AND purpose = ?", authFlowTokenHash(token), match.Purpose)
	if match.Provider != "" {
		query = query.Where("provider = ?", match.Provider)
	}
	if match.Intent != "" {
		query = query.Where("intent = ?", match.Intent)
	}
	if match.UserId != 0 {
		query = query.Where("user_id = ?", match.UserId)
	}
	if match.SessionId != "" {
		query = query.Where("session_id = ?", match.SessionId)
	}
	return query
}

func authFlowTokenHash(token string) string {
	return common.GenerateHMACWithKey([]byte("auth-flow-v1:"+common.SessionSecret), token)
}

func CreateAuthFlow(input AuthFlowCreate) (string, *AuthFlow, error) {
	token, flow, err := CreateAuthFlowWithTx(DB, input)
	if err != nil {
		return "", nil, fmt.Errorf("create auth flow: %w", err)
	}
	return token, flow, nil
}

// CreateAuthFlowWithTx creates a one-time flow in the caller's transaction.
func CreateAuthFlowWithTx(tx *gorm.DB, input AuthFlowCreate) (string, *AuthFlow, error) {
	if tx == nil || strings.TrimSpace(input.Purpose) == "" || input.ExpiresAt.IsZero() || !input.ExpiresAt.After(time.Now().UTC()) {
		return "", nil, ErrAuthFlowInvalid
	}
	random := make([]byte, AuthFlowTokenBytes)
	count, err := cryptorand.Read(random)
	if err != nil {
		return "", nil, fmt.Errorf("generate auth flow token: %w", err)
	}
	if count != len(random) {
		return "", nil, errors.New("generate auth flow token: short random read")
	}
	token := base64.RawURLEncoding.EncodeToString(random)
	flow := &AuthFlow{
		TokenHash: authFlowTokenHash(token),
		Purpose:   input.Purpose,
		Provider:  input.Provider,
		Intent:    input.Intent,
		UserId:    input.UserId,
		SessionId: input.SessionId,
		Payload:   input.Payload,
		ExpiresAt: input.ExpiresAt,
	}
	if err := tx.Create(flow).Error; err != nil {
		return "", nil, fmt.Errorf("create auth flow: %w", err)
	}
	return token, flow, nil
}

// ClaimExternalAuthAssertion records a signed provider assertion as consumed.
// The assertion is HMACed before storage and the unique token_hash index makes
// replay rejection atomic on SQLite, MySQL and PostgreSQL.
func ClaimExternalAuthAssertion(purpose, assertion string, expiresAt time.Time) error {
	err := DB.Transaction(func(tx *gorm.DB) error {
		return ClaimExternalAuthAssertionWithTx(tx, purpose, assertion, expiresAt)
	})
	if err != nil {
		return fmt.Errorf("claim external auth assertion: %w", err)
	}
	return nil
}

// ClaimExternalAuthAssertionWithTx records a provider assertion in the
// caller's transaction so replay protection can commit atomically with the
// authentication flow and its resulting state change.
func ClaimExternalAuthAssertionWithTx(tx *gorm.DB, purpose, assertion string, expiresAt time.Time) error {
	purpose = strings.TrimSpace(purpose)
	assertion = strings.TrimSpace(assertion)
	now := time.Now().UTC()
	if tx == nil || purpose == "" || assertion == "" || !expiresAt.After(now) {
		return ErrAuthFlowInvalid
	}
	flow := AuthFlow{
		TokenHash:  authFlowTokenHash("external:" + purpose + ":" + assertion),
		Purpose:    purpose,
		ExpiresAt:  expiresAt,
		ConsumedAt: &now,
	}
	result := tx.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "token_hash"}},
		DoNothing: true,
	}).Create(&flow)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return ErrAuthFlowConsumed
	}
	return nil
}

// GetAuthFlow validates a flow without consuming it. Callers must still use
// ConsumeAuthFlow with all identity-bound fields before performing the action.
func GetAuthFlow(token string, match AuthFlowMatch) (*AuthFlow, error) {
	if token == "" || match.Purpose == "" {
		return nil, ErrAuthFlowInvalid
	}
	var flow AuthFlow
	if err := applyAuthFlowMatch(DB, token, match).First(&flow).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrAuthFlowInvalid
		}
		return nil, err
	}
	if flow.ConsumedAt != nil {
		return nil, ErrAuthFlowConsumed
	}
	if !flow.ExpiresAt.After(time.Now().UTC()) {
		return nil, ErrAuthFlowExpired
	}
	return &flow, nil
}

// ConsumeAuthFlow atomically validates and consumes a flow. Optional match
// fields are enforced when non-zero so tokens cannot cross purposes or users.
func ConsumeAuthFlow(token string, match AuthFlowMatch) (*AuthFlow, error) {
	flow, err := ConsumeAuthFlowWithAction(token, match, nil)
	if err != nil {
		return nil, fmt.Errorf("consume auth flow: %w", err)
	}
	return flow, nil
}

// ConsumeAuthFlowWithAction consumes a flow and runs action in the same
// database transaction. An action failure rolls the consumption back.
func ConsumeAuthFlowWithAction(token string, match AuthFlowMatch, action func(tx *gorm.DB, flow *AuthFlow) error) (*AuthFlow, error) {
	if token == "" || match.Purpose == "" {
		return nil, ErrAuthFlowInvalid
	}
	var consumed AuthFlow
	err := DB.Transaction(func(tx *gorm.DB) error {
		query := applyAuthFlowMatch(lockForUpdate(tx), token, match)
		if err := query.First(&consumed).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrAuthFlowInvalid
			}
			return err
		}
		if consumed.ConsumedAt != nil {
			return ErrAuthFlowConsumed
		}
		now := time.Now().UTC()
		if !consumed.ExpiresAt.After(now) {
			return ErrAuthFlowExpired
		}
		result := tx.Model(&AuthFlow{}).
			Where("id = ? AND consumed_at IS NULL AND expires_at > ?", consumed.Id, now).
			Update("consumed_at", now)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrAuthFlowConsumed
		}
		consumed.ConsumedAt = &now
		if action != nil {
			if err := action(tx, &consumed); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &consumed, nil
}

func DeleteExpiredAuthFlows(now time.Time) error {
	cutoff := now.Add(-AuthFlowDefaultCleanupRetention)
	return DB.Where("expires_at < ? OR (consumed_at IS NOT NULL AND consumed_at < ?)", cutoff, cutoff).
		Delete(&AuthFlow{}).Error
}
