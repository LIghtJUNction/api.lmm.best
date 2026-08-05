package model

import (
	"time"

	"github.com/QuantumNous/new-api/common"

	"gorm.io/gorm"
)

// ConsoleActivationNeedsLegacyBackfill must be sampled before AutoMigrate.
// A missing column means every row already present belongs to a pre-rollout
// account and must retain full console access after the column is added.
func ConsoleActivationNeedsLegacyBackfill() bool {
	return !DB.Migrator().HasColumn(&User{}, "ConsoleActivatedAt")
}

// InitializeLegacyConsoleActivations is intentionally conditional. Running an
// unconditional zero-value backfill on every boot would activate accounts
// registered after rollout before they create their first credential.
func InitializeLegacyConsoleActivations(backfill bool) error {
	if !backfill {
		return nil
	}
	return DB.Model(&User{}).
		Where("console_activated_at = ?", 0).
		Update("console_activated_at", time.Now().Unix()).Error
}

// InsertTokenAndActivateConsole commits the first credential and permanent
// console activation together. Deleting every credential later does not
// revoke the activation timestamp.
func InsertTokenAndActivateConsole(token *Token) error {
	if token == nil || token.UserId <= 0 {
		return gorm.ErrInvalidData
	}
	now := time.Now().Unix()
	err := DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(token).Error; err != nil {
			return err
		}
		return tx.Model(&User{}).
			Where("id = ? AND console_activated_at = ?", token.UserId, 0).
			Update("console_activated_at", now).Error
	})
	if err != nil {
		return err
	}
	if err := invalidateUserCache(token.UserId); err != nil {
		common.SysLog("failed to invalidate user cache after console activation: " + err.Error())
	}
	return nil
}
