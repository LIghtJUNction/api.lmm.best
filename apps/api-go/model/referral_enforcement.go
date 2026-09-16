package model

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"gorm.io/gorm"
)

// A request key remains consumed after appeal. Replaying an old ban cannot
// disable the user again. A genuinely new case needs a new key.
type ReferralBanCase struct {
	ID              uint   `json:"id" gorm:"primaryKey"`
	InviteeID       int    `json:"invitee_id" gorm:"not null;index"`
	RequestID       string `json:"request_id" gorm:"type:varchar(96);not null;uniqueIndex"`
	Reason          string `json:"reason" gorm:"type:varchar(32);not null"`
	Evidence        string `json:"evidence" gorm:"type:text;not null"`
	PenalizeInviter bool   `json:"penalize_inviter" gorm:"not null;default:false"`
	ReclaimedQuota  int    `json:"reclaimed_quota" gorm:"type:bigint;not null"`
	PenaltyQuota    int    `json:"penalty_quota" gorm:"type:bigint;not null"`
	PreviousStatus  int    `json:"previous_status" gorm:"not null"`
	ActorID         int    `json:"actor_id" gorm:"not null"`
	CreatedAt       int64  `json:"created_at" gorm:"autoCreateTime;index"`
	RestoredAt      int64  `json:"restored_at" gorm:"not null;default:0"`
	RestoredBy      int    `json:"restored_by" gorm:"not null;default:0"`
	RestoreReason   string `json:"restore_reason" gorm:"type:text;not null"`
}

type ReferralBanInput struct {
	UserID          int    `json:"user_id"`
	RequestID       string `json:"request_id"`
	Reason          string `json:"reason"`
	Evidence        string `json:"evidence"`
	PenalizeInviter bool   `json:"penalize_inviter"`
	ActorID         int    `json:"-"`
}

func referralAdminTx(tx *gorm.DB, actorID int, target *User) error {
	var actor User
	if err := tx.Select("id", "role", "status").First(&actor, actorID).Error; err != nil {
		return err
	}
	if actor.Status != common.UserStatusEnabled || actor.Role < common.RoleAdminUser ||
		target.Id == actorID || target.Role >= actor.Role || target.Role == common.RoleRootUser {
		return ErrReferralPermission
	}
	return nil
}

func referralTransaction(fn func(*gorm.DB) error) error {
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		err = DB.Transaction(fn)
		if err == nil {
			return nil
		}
		message := strings.ToLower(err.Error())
		if !errors.Is(err, ErrReferralConflict) && !uniqueConstraintError(err) &&
			!strings.Contains(message, "locked") && !strings.Contains(message, "deadlock") && !strings.Contains(message, "serialization") {
			return err
		}
		time.Sleep(time.Duration(attempt+1) * 10 * time.Millisecond)
	}
	return err
}

func publishReferralEnforcement(userID int) error {
	if err := PublishUserAuthCache(userID); err != nil {
		return err
	}
	if err := InvalidateUserTokensCache(userID); err != nil {
		return err
	}
	_, err := RevokeAllUserSessions(userID, "referral_enforcement")
	return err
}

func BanReferralInvitee(input ReferralBanInput) (*ReferralBanCase, error) {
	input.RequestID = strings.TrimSpace(input.RequestID)
	input.Evidence = strings.TrimSpace(input.Evidence)
	if DB == nil || input.UserID <= 0 || input.ActorID <= 0 || len(input.RequestID) < 8 || len(input.RequestID) > 96 ||
		(input.Reason != "abuse" && input.Reason != "bulk_registration") ||
		len([]rune(input.Evidence)) < 5 || len([]rune(input.Evidence)) > 2000 {
		return nil, gorm.ErrInvalidData
	}
	var result ReferralBanCase
	err := referralTransaction(func(tx *gorm.DB) error {
		result = ReferralBanCase{}
		var invitee User
		if err := lockForUpdate(tx).First(&invitee, input.UserID).Error; err != nil {
			return err
		}
		if err := referralAdminTx(tx, input.ActorID, &invitee); err != nil {
			return err
		}
		err := tx.Where("request_id = ?", input.RequestID).First(&result).Error
		if err == nil {
			if result.InviteeID != input.UserID || result.ActorID != input.ActorID || result.Reason != input.Reason ||
				result.Evidence != input.Evidence || result.PenalizeInviter != input.PenalizeInviter {
				return ErrReferralConflict
			}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if invitee.ReferralBanCaseID != 0 {
			return ErrReferralBanActive
		}
		result = ReferralBanCase{InviteeID: invitee.Id, RequestID: input.RequestID, Reason: input.Reason,
			Evidence: input.Evidence, PenalizeInviter: input.PenalizeInviter,
			ActorID: input.ActorID, PreviousStatus: invitee.Status}
		if err := tx.Create(&result).Error; err != nil {
			return err
		}
		var reward ReferralReward
		err = lockForUpdate(tx).Where("invitee_id = ?", invitee.Id).First(&reward).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if err == nil && reward.Quota > 0 {
			if reward.BanCaseID != 0 {
				return ErrReferralConflict
			}
			result.ReclaimedQuota = reward.Quota - reward.RefundReclaimedQuota
			key := fmt.Sprintf("ban:%d", result.ID)
			if err := appendReferralEntryTx(tx, &reward, key+":reclaim", "abuse_reclaim", input.Reason, -result.ReclaimedQuota, input.ActorID); err != nil {
				return err
			}
			if input.PenalizeInviter && reward.PenaltyQuota > 0 {
				var inviter User
				if err := tx.Unscoped().First(&inviter, reward.InviterID).Error; err != nil {
					return err
				}
				if err := referralAdminTx(tx, input.ActorID, &inviter); err != nil {
					return err
				}
				result.PenaltyQuota = reward.PenaltyQuota
				if err := appendReferralEntryTx(tx, &reward, key+":penalty", "penalty", input.Reason, -result.PenaltyQuota, input.ActorID); err != nil {
					return err
				}
			}
			if err := tx.Model(&reward).Update("ban_case_id", result.ID).Error; err != nil {
				return err
			}
		}
		if err := tx.Model(&result).Updates(map[string]interface{}{
			"reclaimed_quota": result.ReclaimedQuota, "penalty_quota": result.PenaltyQuota,
		}).Error; err != nil {
			return err
		}
		if _, err := IncrementUserAuthVersionWithTx(tx, invitee.Id); err != nil {
			return err
		}
		return tx.Model(&User{}).Where("id = ?", invitee.Id).Updates(map[string]interface{}{
			"status": common.UserStatusDisabled, "referral_ban_case_id": result.ID,
		}).Error
	})
	if err != nil {
		return nil, err
	}
	// Repeat cache/session publication after a retry of a committed operation.
	if result.RestoredAt == 0 {
		if err := publishReferralEnforcement(result.InviteeID); err != nil {
			return &result, err
		}
	}
	return &result, nil
}

func RestoreReferralBan(caseID uint, userID, actorID int, reason string) (*ReferralBanCase, error) {
	reason = strings.TrimSpace(reason)
	if DB == nil || caseID == 0 || userID <= 0 || actorID <= 0 || len([]rune(reason)) < 5 || len([]rune(reason)) > 2000 {
		return nil, gorm.ErrInvalidData
	}
	var result ReferralBanCase
	err := referralTransaction(func(tx *gorm.DB) error {
		result = ReferralBanCase{}
		var invitee User
		if err := lockForUpdate(tx).First(&invitee, userID).Error; err != nil {
			return err
		}
		if err := referralAdminTx(tx, actorID, &invitee); err != nil {
			return err
		}
		if err := lockForUpdate(tx).Where("id = ? AND invitee_id = ?", caseID, userID).First(&result).Error; err != nil {
			return err
		}
		if result.RestoredAt != 0 {
			return nil
		}
		if invitee.ReferralBanCaseID != result.ID {
			return ErrReferralConflict
		}
		var reward ReferralReward
		err := lockForUpdate(tx).Where("invitee_id = ?", userID).First(&reward).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if err == nil && reward.Quota > 0 {
			if reward.BanCaseID != caseID {
				return ErrReferralConflict
			}
			key := fmt.Sprintf("restore:%d", caseID)
			remaining := reward.Quota - reward.RefundReclaimedQuota
			if err := appendReferralEntryTx(tx, &reward, key+":reward", "reward_restore", "ban_reversed", remaining, actorID); err != nil {
				return err
			}
			if err := appendReferralEntryTx(tx, &reward, key+":penalty", "penalty_restore", "ban_reversed", result.PenaltyQuota, actorID); err != nil {
				return err
			}
			if err := tx.Model(&reward).Update("ban_case_id", 0).Error; err != nil {
				return err
			}
		}
		result.RestoredAt, result.RestoredBy, result.RestoreReason = common.GetTimestamp(), actorID, reason
		if err := tx.Model(&result).Updates(map[string]interface{}{
			"restored_at": result.RestoredAt, "restored_by": actorID, "restore_reason": reason,
		}).Error; err != nil {
			return err
		}
		if _, err := IncrementUserAuthVersionWithTx(tx, invitee.Id); err != nil {
			return err
		}
		return tx.Model(&User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"status": result.PreviousStatus, "referral_ban_case_id": 0,
		}).Error
	})
	if err != nil {
		return nil, err
	}
	if err := publishReferralEnforcement(userID); err != nil {
		return &result, err
	}
	return &result, nil
}
