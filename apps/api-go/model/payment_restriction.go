package model

import (
	"strings"

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

func PopulateAdminPaymentRestriction(user *User) {
	if user == nil {
		return
	}
	user.AdminPaymentRestrictionFlags = EffectivePaymentRestrictionFlags(user)
}

func PopulateAdminPaymentRestrictions(users []*User) {
	for _, user := range users {
		PopulateAdminPaymentRestriction(user)
	}
}
