package model

import (
	"errors"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

var ErrAssistantWeeklyCreditRefundExceedsUsage = errors.New("assistant weekly credit refund exceeds usage")

// AssistantWeeklyUsage stores the system-funded assistant quota consumed by
// one user during one ISO week. Quota uses the same integer unit as user
// balances so relay billing can split a request without a second conversion.
type AssistantWeeklyUsage struct {
	Id        int   `json:"id" gorm:"primaryKey;autoIncrement"`
	UserId    int   `json:"user_id" gorm:"not null;uniqueIndex:idx_assistant_user_week"`
	WeekStart int64 `json:"week_start" gorm:"bigint;not null;uniqueIndex:idx_assistant_user_week"`
	UsedQuota int64 `json:"used_quota" gorm:"bigint;not null;default:0"`
	CreatedAt int64 `json:"created_at" gorm:"bigint;autoCreateTime"`
	UpdatedAt int64 `json:"updated_at" gorm:"bigint;autoUpdateTime"`
}

func (AssistantWeeklyUsage) TableName() string {
	return "assistant_weekly_usages"
}

// AssistantWeekStartUTC returns Monday 00:00:00 UTC for the supplied time.
func AssistantWeekStartUTC(now time.Time) int64 {
	utc := now.UTC()
	dayStart := time.Date(utc.Year(), utc.Month(), utc.Day(), 0, 0, 0, 0, time.UTC)
	daysSinceMonday := (int(dayStart.Weekday()) + 6) % 7
	return dayStart.AddDate(0, 0, -daysSinceMonday).Unix()
}

func GetAssistantWeeklyUsage(userId int, weekStart int64) (int64, error) {
	if userId <= 0 {
		return 0, errors.New("assistant user id must be positive")
	}
	var usage AssistantWeeklyUsage
	err := DB.Where("user_id = ? AND week_start = ?", userId, weekStart).First(&usage).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return usage.UsedQuota, nil
}

// ReserveAssistantWeeklyCredit atomically reserves up to requested quota from
// the user's current weekly allowance and returns the amount actually covered.
func ReserveAssistantWeeklyCredit(userId int, weekStart int64, weeklyLimit int64, requested int) (int, error) {
	if userId <= 0 {
		return 0, errors.New("assistant user id must be positive")
	}
	if weeklyLimit <= 0 || requested <= 0 {
		return 0, nil
	}

	var reserved int64
	err := DB.Transaction(func(tx *gorm.DB) error {
		usage := AssistantWeeklyUsage{UserId: userId, WeekStart: weekStart}
		if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&usage).Error; err != nil {
			return err
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("user_id = ? AND week_start = ?", userId, weekStart).
			First(&usage).Error; err != nil {
			return err
		}

		remaining := weeklyLimit - usage.UsedQuota
		if remaining <= 0 {
			return nil
		}
		reserved = int64(requested)
		if reserved > remaining {
			reserved = remaining
		}
		return tx.Model(&AssistantWeeklyUsage{}).
			Where("id = ?", usage.Id).
			UpdateColumn("used_quota", gorm.Expr("used_quota + ?", reserved)).Error
	})
	return int(reserved), err
}

// RefundAssistantWeeklyCredit releases a previous reservation. Rejecting an
// over-refund keeps accounting failures visible instead of silently minting
// additional weekly allowance.
func RefundAssistantWeeklyCredit(userId int, weekStart int64, amount int) error {
	if amount <= 0 {
		return nil
	}
	return DB.Transaction(func(tx *gorm.DB) error {
		var usage AssistantWeeklyUsage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("user_id = ? AND week_start = ?", userId, weekStart).
			First(&usage).Error; err != nil {
			return err
		}
		if int64(amount) > usage.UsedQuota {
			return ErrAssistantWeeklyCreditRefundExceedsUsage
		}
		return tx.Model(&AssistantWeeklyUsage{}).
			Where("id = ?", usage.Id).
			UpdateColumn("used_quota", gorm.Expr("used_quota - ?", amount)).Error
	})
}
