package model

import (
	"strings"
	"time"

	"gorm.io/gorm"
)

const (
	PaymentRestrictionLinuxDOEmail = 1 << iota
	PaymentRestrictionLinuxDOHighScore
)

const LinuxDOGamificationScorePaymentThreshold = 10_000

func IsLinuxDOEmail(email string) bool {
	email = NormalizeEmail(email)
	at := strings.LastIndexByte(email, '@')
	return at > 0 && strings.EqualFold(email[at+1:], "linux.do")
}

func EffectivePaymentRestrictionFlags(user *User) int {
	if user == nil {
		return 0
	}
	flags := user.PaymentRestrictionFlags
	if IsLinuxDOEmail(user.Email) {
		flags |= PaymentRestrictionLinuxDOEmail
	}
	return flags
}

func IsPaymentRestricted(user *User) bool {
	return EffectivePaymentRestrictionFlags(user) != 0
}

func AddPaymentRestrictionFlags(userID int, flags int) error {
	if userID <= 0 || flags == 0 {
		return gorm.ErrInvalidData
	}
	result := DB.Model(&User{}).
		Where("id = ?", userID).
		UpdateColumn("payment_restriction_flags", gorm.Expr("payment_restriction_flags | ?", flags))
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return invalidateUserCache(userID)
}

// UpdateLinuxDOGamificationScore records the current score used by payment
// audience rules and keeps the legacy high-score marker in sync. Older builds
// only persisted the marker, so the marker remains a fallback until a user
// signs in with LinuxDO again and refreshes the exact score.
func UpdateLinuxDOGamificationScore(userID int, score float64) error {
	if userID <= 0 || score < 0 {
		return gorm.ErrInvalidData
	}
	err := DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"linux_do_gamification_score": score,
			"linux_do_score_updated_at":   time.Now().Unix(),
		}).Error; err != nil {
			return err
		}

		flagsExpression := gorm.Expr("payment_restriction_flags & ?", ^PaymentRestrictionLinuxDOHighScore)
		if score > LinuxDOGamificationScorePaymentThreshold {
			flagsExpression = gorm.Expr("payment_restriction_flags | ?", PaymentRestrictionLinuxDOHighScore)
		}
		if err := tx.Model(&User{}).Where("id = ?", userID).
			UpdateColumn("payment_restriction_flags", flagsExpression).Error; err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return err
	}
	return invalidateUserCache(userID)
}

func LinuxDOGamificationScoreForAudience(user *User) (float64, bool) {
	if user == nil {
		return 0, false
	}
	if user.LinuxDOScoreUpdatedAt > 0 {
		return user.LinuxDOGamificationScore, true
	}
	if EffectivePaymentRestrictionFlags(user)&PaymentRestrictionLinuxDOHighScore != 0 {
		return float64(LinuxDOGamificationScorePaymentThreshold) + 1, true
	}
	return 0, false
}

func PopulateAdminPaymentRestriction(user *User) {
	if user == nil {
		return
	}
	user.AdminPaymentRestrictionFlags = EffectivePaymentRestrictionFlags(user)
	if user.LinuxDOScoreUpdatedAt > 0 {
		score := user.LinuxDOGamificationScore
		user.AdminLinuxDOGamificationScore = &score
	}
	user.AdminLinuxDOScoreUpdatedAt = user.LinuxDOScoreUpdatedAt
}

func PopulateAdminPaymentRestrictions(users []*User) {
	for _, user := range users {
		PopulateAdminPaymentRestriction(user)
	}
}
