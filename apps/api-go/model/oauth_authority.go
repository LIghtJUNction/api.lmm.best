package model

import (
	cryptorand "crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	oauthFamilyLockNamespace int64 = 0x4f41555448

	OAuthDeviceStatusPending  = "pending"
	OAuthDeviceStatusApproved = "approved"
	OAuthDeviceStatusDenied   = "denied"

	OAuthTokenKindAccess  = "access"
	OAuthTokenKindRefresh = "refresh"

	oauthDeviceCodeBytes = 32
	oauthTokenBytes      = 32
)

var (
	ErrOAuthInvalidGrant         = errors.New("invalid oauth grant")
	ErrOAuthAuthorizationPending = errors.New("oauth authorization pending")
	ErrOAuthSlowDown             = errors.New("oauth polling too quickly")
	ErrOAuthAccessDenied         = errors.New("oauth access denied")
	ErrOAuthExpiredToken         = errors.New("oauth token expired")
	ErrOAuthRefreshReplay        = errors.New("oauth refresh token replayed")
)

// OAuthDeviceGrant is the authoritative state for RFC 8628 device authorization.
// Only keyed hashes of device_code and user_code are persisted.
type OAuthDeviceGrant struct {
	Id              int64      `json:"id" gorm:"primaryKey"`
	DeviceCodeHash  string     `json:"-" gorm:"type:char(64);not null;uniqueIndex"`
	UserCodeHash    string     `json:"-" gorm:"type:char(64);not null;uniqueIndex"`
	ClientId        string     `json:"client_id" gorm:"type:varchar(64);not null;index"`
	Scopes          string     `json:"scopes" gorm:"type:text;not null"`
	Status          string     `json:"status" gorm:"type:varchar(16);not null;index"`
	UserId          int        `json:"user_id,omitempty" gorm:"index"`
	IntervalSeconds int        `json:"interval_seconds" gorm:"not null"`
	LastPolledAt    *time.Time `json:"last_polled_at,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	ExpiresAt       time.Time  `json:"expires_at" gorm:"not null;index"`
	ConsumedAt      *time.Time `json:"consumed_at,omitempty" gorm:"index"`
}

func (OAuthDeviceGrant) TableName() string { return "oauth_device_grants" }

// OAuthGrantToken stores only an HMAC of an OAuth access or refresh token.
type OAuthGrantToken struct {
	Id         int64      `json:"id" gorm:"primaryKey"`
	TokenHash  string     `json:"-" gorm:"type:char(64);not null;uniqueIndex"`
	Kind       string     `json:"kind" gorm:"type:varchar(16);not null;index:idx_oauth_token_family_kind"`
	FamilyId   string     `json:"family_id" gorm:"type:char(36);not null;index:idx_oauth_token_family_kind"`
	ClientId   string     `json:"client_id" gorm:"type:varchar(64);not null;index"`
	UserId     int        `json:"user_id" gorm:"not null;index"`
	Scopes     string     `json:"scopes" gorm:"type:text;not null"`
	CreatedAt  time.Time  `json:"created_at"`
	ExpiresAt  time.Time  `json:"expires_at" gorm:"not null;index"`
	ConsumedAt *time.Time `json:"consumed_at,omitempty" gorm:"index"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty" gorm:"index"`
}

func (OAuthGrantToken) TableName() string { return "oauth_grant_tokens" }

type OAuthTokenPair struct {
	AccessToken      string
	RefreshToken     string
	AccessExpiresAt  time.Time
	RefreshExpiresAt time.Time
	FamilyId         string
	Scopes           string
}

func CreateOAuthDeviceGrant(clientId, scopes string, expiresAt time.Time, intervalSeconds int) (string, string, *OAuthDeviceGrant, error) {
	if strings.TrimSpace(clientId) == "" || strings.TrimSpace(scopes) == "" || !expiresAt.After(time.Now()) || intervalSeconds < 1 {
		return "", "", nil, ErrOAuthInvalidGrant
	}
	deviceCode, err := randomOAuthValue(oauthDeviceCodeBytes)
	if err != nil {
		return "", "", nil, err
	}
	userCode, err := randomOAuthUserCode()
	if err != nil {
		return "", "", nil, err
	}
	grant := &OAuthDeviceGrant{
		DeviceCodeHash:  oauthOpaqueHash("device-code", deviceCode),
		UserCodeHash:    oauthOpaqueHash("user-code", normalizeOAuthUserCode(userCode)),
		ClientId:        clientId,
		Scopes:          scopes,
		Status:          OAuthDeviceStatusPending,
		IntervalSeconds: intervalSeconds,
		ExpiresAt:       expiresAt,
	}
	if err := DB.Create(grant).Error; err != nil {
		return "", "", nil, err
	}
	return deviceCode, userCode, grant, nil
}

func ApproveOAuthDeviceGrant(userCode string, userId int, approve bool, now time.Time) (*OAuthDeviceGrant, error) {
	if userId <= 0 {
		return nil, ErrOAuthInvalidGrant
	}
	var approved *OAuthDeviceGrant
	err := DB.Transaction(func(tx *gorm.DB) error {
		var grant OAuthDeviceGrant
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"user_code_hash = ?", oauthOpaqueHash("user-code", normalizeOAuthUserCode(userCode)),
		).First(&grant).Error; err != nil {
			return normalizeOAuthRecordError(err)
		}
		if grant.ConsumedAt != nil || !grant.ExpiresAt.After(now) || grant.Status != OAuthDeviceStatusPending {
			return ErrOAuthInvalidGrant
		}
		status := OAuthDeviceStatusDenied
		if approve {
			status = OAuthDeviceStatusApproved
		}
		if err := tx.Model(&OAuthDeviceGrant{}).Where(
			"id = ? AND status = ? AND consumed_at IS NULL", grant.Id, OAuthDeviceStatusPending,
		).Updates(map[string]any{"status": status, "user_id": userId}).Error; err != nil {
			return err
		}
		grant.Status = status
		grant.UserId = userId
		approved = &grant
		return nil
	})
	return approved, err
}

// ConsumeOAuthDeviceGrant enforces the polling interval and consumes an approved
// grant exactly once. Pending and slow-down responses leave the grant reusable.
func ConsumeOAuthDeviceGrant(deviceCode, clientId string, now time.Time) (*OAuthDeviceGrant, error) {
	grant, err := ConsumeOAuthDeviceGrantWithAction(deviceCode, clientId, now, nil)
	if err != nil {
		return nil, fmt.Errorf("consume oauth device grant: %w", err)
	}
	return grant, nil
}

// ConsumeOAuthDeviceGrantWithAction consumes the grant and commits the caller's
// token issuance action in the same transaction.
func ConsumeOAuthDeviceGrantWithAction(
	deviceCode, clientId string,
	now time.Time,
	action func(tx *gorm.DB, grant *OAuthDeviceGrant) error,
) (*OAuthDeviceGrant, error) {
	var consumed *OAuthDeviceGrant
	var outcome error
	err := DB.Transaction(func(tx *gorm.DB) error {
		var grant OAuthDeviceGrant
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"device_code_hash = ? AND client_id = ?", oauthOpaqueHash("device-code", deviceCode), clientId,
		).First(&grant).Error; err != nil {
			return normalizeOAuthRecordError(err)
		}
		if grant.ConsumedAt != nil {
			return ErrOAuthInvalidGrant
		}
		if !grant.ExpiresAt.After(now) {
			return ErrOAuthExpiredToken
		}
		if grant.LastPolledAt != nil && now.Before(grant.LastPolledAt.Add(time.Duration(grant.IntervalSeconds)*time.Second)) {
			grant.IntervalSeconds += 5
			if err := tx.Model(&OAuthDeviceGrant{}).Where("id = ?", grant.Id).Updates(map[string]any{
				"interval_seconds": grant.IntervalSeconds,
				"last_polled_at":   now,
			}).Error; err != nil {
				return err
			}
			outcome = ErrOAuthSlowDown
			return nil
		}
		if err := tx.Model(&OAuthDeviceGrant{}).Where("id = ?", grant.Id).Update("last_polled_at", now).Error; err != nil {
			return err
		}
		switch grant.Status {
		case OAuthDeviceStatusPending:
			outcome = ErrOAuthAuthorizationPending
			return nil
		case OAuthDeviceStatusDenied:
			outcome = ErrOAuthAccessDenied
			return nil
		case OAuthDeviceStatusApproved:
			if grant.UserId <= 0 {
				return ErrOAuthInvalidGrant
			}
		default:
			return ErrOAuthInvalidGrant
		}
		if action != nil {
			if err := action(tx, &grant); err != nil {
				return fmt.Errorf("consume oauth device grant action: %w", err)
			}
		}
		result := tx.Model(&OAuthDeviceGrant{}).Where(
			"id = ? AND consumed_at IS NULL", grant.Id,
		).Update("consumed_at", now)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrOAuthInvalidGrant
		}
		grant.ConsumedAt = &now
		consumed = &grant
		return nil
	})
	if err != nil {
		return nil, err
	}
	if outcome != nil {
		return nil, outcome
	}
	return consumed, nil
}

func CreateOAuthTokenPair(tx *gorm.DB, clientId string, userId int, scopes string, accessTTL, refreshTTL time.Duration, now time.Time) (*OAuthTokenPair, error) {
	pair, err := createOAuthTokenPair(tx, uuid.NewString(), clientId, userId, scopes, accessTTL, refreshTTL, now)
	if err != nil {
		return nil, fmt.Errorf("create oauth token pair: %w", err)
	}
	return pair, nil
}

func createOAuthTokenPair(tx *gorm.DB, familyId, clientId string, userId int, scopes string, accessTTL, refreshTTL time.Duration, now time.Time) (*OAuthTokenPair, error) {
	if tx == nil || userId <= 0 || clientId == "" || scopes == "" || accessTTL <= 0 || refreshTTL <= 0 {
		return nil, ErrOAuthInvalidGrant
	}
	accessToken, err := randomOAuthValue(oauthTokenBytes)
	if err != nil {
		return nil, err
	}
	refreshToken, err := randomOAuthValue(oauthTokenBytes)
	if err != nil {
		return nil, err
	}
	pair := &OAuthTokenPair{
		AccessToken:      "lmm_oat_" + accessToken,
		RefreshToken:     "lmm_ort_" + refreshToken,
		AccessExpiresAt:  now.Add(accessTTL),
		RefreshExpiresAt: now.Add(refreshTTL),
		FamilyId:         familyId,
		Scopes:           scopes,
	}
	records := []OAuthGrantToken{
		{
			TokenHash: oauthOpaqueHash(OAuthTokenKindAccess, pair.AccessToken), Kind: OAuthTokenKindAccess,
			FamilyId: familyId, ClientId: clientId, UserId: userId, Scopes: scopes,
			ExpiresAt: pair.AccessExpiresAt,
		},
		{
			TokenHash: oauthOpaqueHash(OAuthTokenKindRefresh, pair.RefreshToken), Kind: OAuthTokenKindRefresh,
			FamilyId: familyId, ClientId: clientId, UserId: userId, Scopes: scopes,
			ExpiresAt: pair.RefreshExpiresAt,
		},
	}
	if err := tx.Create(&records).Error; err != nil {
		return nil, err
	}
	return pair, nil
}

func ValidateOAuthAccessToken(raw string, now time.Time) (*OAuthGrantToken, error) {
	if !strings.HasPrefix(raw, "lmm_oat_") {
		return nil, ErrOAuthInvalidGrant
	}
	var token OAuthGrantToken
	if err := DB.Where(
		"token_hash = ? AND kind = ?", oauthOpaqueHash(OAuthTokenKindAccess, raw), OAuthTokenKindAccess,
	).First(&token).Error; err != nil {
		return nil, normalizeOAuthRecordError(err)
	}
	if token.RevokedAt != nil || token.ConsumedAt != nil || !token.ExpiresAt.After(now) {
		return nil, ErrOAuthExpiredToken
	}
	return &token, nil
}

func RotateOAuthRefreshToken(raw, clientId string, accessTTL, refreshTTL time.Duration, now time.Time) (*OAuthTokenPair, error) {
	if !strings.HasPrefix(raw, "lmm_ort_") {
		return nil, ErrOAuthInvalidGrant
	}
	var pair *OAuthTokenPair
	var replayed bool
	tokenHash := oauthOpaqueHash(OAuthTokenKindRefresh, raw)
	err := DB.Transaction(func(tx *gorm.DB) error {
		var family OAuthGrantToken
		if err := tx.Select("family_id").Where(
			"token_hash = ? AND kind = ? AND client_id = ?",
			tokenHash, OAuthTokenKindRefresh, clientId,
		).First(&family).Error; err != nil {
			return normalizeOAuthRecordError(err)
		}
		if err := lockOAuthTokenFamily(tx, family.FamilyId); err != nil {
			return err
		}
		var token OAuthGrantToken
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"token_hash = ? AND kind = ? AND client_id = ?",
			tokenHash, OAuthTokenKindRefresh, clientId,
		).First(&token).Error; err != nil {
			return normalizeOAuthRecordError(err)
		}
		if token.ConsumedAt != nil || token.RevokedAt != nil {
			if err := tx.Model(&OAuthGrantToken{}).Where(
				"family_id = ? AND revoked_at IS NULL", token.FamilyId,
			).Update("revoked_at", now).Error; err != nil {
				return err
			}
			replayed = true
			return nil
		}
		if !token.ExpiresAt.After(now) {
			return ErrOAuthExpiredToken
		}
		result := tx.Model(&OAuthGrantToken{}).Where(
			"id = ? AND consumed_at IS NULL AND revoked_at IS NULL", token.Id,
		).Update("consumed_at", now)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrOAuthRefreshReplay
		}
		var err error
		pair, err = createOAuthTokenPair(
			tx, token.FamilyId, token.ClientId, token.UserId, token.Scopes,
			accessTTL, refreshTTL, now,
		)
		return err
	})
	if err != nil {
		return nil, err
	}
	if replayed {
		return nil, ErrOAuthRefreshReplay
	}
	return pair, nil
}

func RevokeOAuthToken(raw string, now time.Time) error {
	kind := OAuthTokenKindAccess
	if strings.HasPrefix(raw, "lmm_ort_") {
		kind = OAuthTokenKindRefresh
	} else if !strings.HasPrefix(raw, "lmm_oat_") {
		return nil
	}
	tokenHash := oauthOpaqueHash(kind, raw)
	err := DB.Transaction(func(tx *gorm.DB) error {
		var family OAuthGrantToken
		err := tx.Select("family_id").Where("token_hash = ? AND kind = ?", tokenHash, kind).First(&family).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("find oauth token family for revocation: %w", err)
		}
		if err := lockOAuthTokenFamily(tx, family.FamilyId); err != nil {
			return err
		}
		var token OAuthGrantToken
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"token_hash = ? AND kind = ?", tokenHash, kind,
		).First(&token).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return fmt.Errorf("find oauth token for revocation: %w", err)
		}
		query := tx.Model(&OAuthGrantToken{}).Where("id = ?", token.Id)
		if kind == OAuthTokenKindRefresh {
			query = tx.Model(&OAuthGrantToken{}).Where("family_id = ?", token.FamilyId)
		}
		if err := query.Where("revoked_at IS NULL").Update("revoked_at", now).Error; err != nil {
			return fmt.Errorf("mark oauth token revoked: %w", err)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("revoke oauth token: %w", err)
	}
	return nil
}

func lockOAuthTokenFamily(tx *gorm.DB, familyId string) error {
	if tx.Dialector.Name() != "postgres" {
		return nil
	}
	return tx.Exec(
		"SELECT pg_advisory_xact_lock(hashtextextended(?, ?))",
		familyId, oauthFamilyLockNamespace,
	).Error
}

func randomOAuthValue(size int) (string, error) {
	value := make([]byte, size)
	count, err := cryptorand.Read(value)
	if err != nil {
		return "", fmt.Errorf("generate oauth secret: %w", err)
	}
	if count != len(value) {
		return "", errors.New("generate oauth secret: short random read")
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func randomOAuthUserCode() (string, error) {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	value := make([]byte, 8)
	random := make([]byte, len(value))
	count, err := cryptorand.Read(random)
	if err != nil {
		return "", fmt.Errorf("generate oauth user code: %w", err)
	}
	if count != len(random) {
		return "", errors.New("generate oauth user code: short random read")
	}
	for index := range value {
		value[index] = alphabet[int(random[index])%len(alphabet)]
	}
	return string(value[:4]) + "-" + string(value[4:]), nil
}

func normalizeOAuthUserCode(value string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(value), "-", ""))
}

func oauthOpaqueHash(kind, token string) string {
	return authFlowTokenHash("oauth:" + kind + ":" + token)
}

func normalizeOAuthRecordError(err error) error {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return ErrOAuthInvalidGrant
	}
	return err
}
