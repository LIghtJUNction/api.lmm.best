package model

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/setting/operation_setting"
	"gorm.io/gorm"
)

var (
	ErrReferralDebt       = errors.New("referral rewards must repay the outstanding referral debt before transfer")
	ErrReferralBanActive  = errors.New("resolve the active referral abuse case before enabling this user")
	ErrReferralConflict   = errors.New("referral operation conflicts with an existing case")
	ErrReferralPermission = errors.New("insufficient permission for referral enforcement")
)

// One immutable award snapshot per invitee. Zero-quota rows consume a first
// payment that was below threshold, disabled, or otherwise ineligible.
type ReferralReward struct {
	ID                   uint   `json:"id" gorm:"primaryKey"`
	InviteeID            int    `json:"invitee_id" gorm:"not null;uniqueIndex"`
	InviterID            int    `json:"inviter_id" gorm:"not null;index"`
	TopUpID              int    `json:"topup_id" gorm:"not null;uniqueIndex"`
	Quota                int    `json:"quota" gorm:"type:bigint;not null"`
	PenaltyQuota         int    `json:"penalty_quota" gorm:"type:bigint;not null"`
	RefundReclaimedQuota int    `json:"refund_reclaimed_quota" gorm:"type:bigint;not null;default:0"`
	BanCaseID            uint   `json:"ban_case_id" gorm:"not null;default:0"`
	Reason               string `json:"reason" gorm:"type:varchar(64);not null"`
	CreatedAt            int64  `json:"created_at" gorm:"autoCreateTime;index"`
}

// Entries are append-only. Balance and debt are both nonnegative. A positive
// award first repays debt; a debit never touches the paid wallet (users.quota).
type ReferralLedgerEntry struct {
	ID           uint   `json:"id" gorm:"primaryKey;index:idx_referral_ledger_owner_id,priority:2"`
	InviterID    int    `json:"-" gorm:"not null;index:idx_referral_ledger_owner_id,priority:1"`
	InviteeID    int    `json:"invitee_id" gorm:"not null"`
	RewardID     uint   `json:"reward_id" gorm:"not null;index"`
	OperationKey string `json:"-" gorm:"type:varchar(128);not null;uniqueIndex"`
	Kind         string `json:"kind" gorm:"type:varchar(32);not null"`
	QuotaDelta   int    `json:"quota_delta" gorm:"type:bigint;not null"`
	BalanceDelta int    `json:"balance_delta" gorm:"type:bigint;not null"`
	DebtDelta    int    `json:"debt_delta" gorm:"type:bigint;not null"`
	BalanceAfter int    `json:"balance_after" gorm:"type:bigint;not null"`
	DebtAfter    int    `json:"debt_after" gorm:"type:bigint;not null"`
	Reason       string `json:"reason" gorm:"type:varchar(64);not null"`
	ActorID      int    `json:"-" gorm:"not null"`
	CreatedAt    int64  `json:"created_at" gorm:"autoCreateTime;index"`
}

// createUserWithReferralTx binds once at registration, and counts the invite
// in the same transaction. Existing rows keep eligibility=false on migration:
// old registration bonuses cannot safely be attributed and must not be paid twice.
func createUserWithReferralTx(tx *gorm.DB, user *User, inviterID int) error {
	user.InviterId = 0
	user.ReferralFirstTopUpEligible = false
	var inviter User
	if inviterID > 0 {
		if inviterID == user.Id {
			return gorm.ErrInvalidData
		}
		if err := lockForUpdate(tx).First(&inviter, inviterID).Error; err != nil {
			return err
		}
		if inviter.Status != common.UserStatusEnabled {
			return gorm.ErrInvalidData
		}
		user.InviterId = inviterID
		user.ReferralFirstTopUpEligible = true
	}
	if err := tx.Create(user).Error; err != nil {
		return err
	}
	if inviterID > 0 && promotionRewardsAllowedForUser(user) && promotionRewardsAllowedForUser(&inviter) {
		return tx.Model(&User{}).Where("id = ?", inviterID).
			Update("aff_count", boundedInt32CounterExpr("aff_count", 1)).Error
	}
	return nil
}

func referralCashTopUp(topUp *TopUp) bool {
	if topUp == nil || topUp.Status != common.TopUpStatusSuccess || topUp.CreditedQuota <= 0 ||
		topUp.SettledAmountMicros <= 0 || !IsFinancialPaymentSource(topUp.PaymentMethod, topUp.PaymentProvider) {
		return false
	}
	switch topUp.PaymentProvider {
	case PaymentProviderEpay, PaymentProviderStripe, PaymentProviderCreem, PaymentProviderWaffo, PaymentProviderWaffoPancake:
	default:
		return false
	}
	currency := strings.ToUpper(strings.TrimSpace(topUp.SettlementCurrency))
	if currency == "" || currency == "LDC" {
		return false
	}
	if topUp.PaymentProvider == PaymentProviderEpay && strings.EqualFold(topUp.PaymentMethod, PaymentProviderEpay) && currency != "CNY" {
		return false
	}
	return true
}

func referralBalanceDelta(balance, debt, delta int) (newBalance, newDebt int, err error) {
	if balance < 0 || debt < 0 || balance > common.MaxWalletQuota || debt > common.MaxWalletQuota ||
		(balance > 0 && debt > 0) || delta < -common.MaxWalletQuota || delta > common.MaxWalletQuota {
		return 0, 0, ErrWalletQuotaOutOfRange
	}
	newBalance, newDebt = balance, debt
	if delta >= 0 {
		offset := min(debt, delta)
		newDebt -= offset
		credit := delta - offset
		if credit > common.MaxWalletQuota-balance {
			return 0, 0, ErrWalletQuotaOutOfRange
		}
		newBalance += credit
	} else {
		debit := -delta
		collected := min(balance, debit)
		newBalance -= collected
		shortfall := debit - collected
		if shortfall > common.MaxWalletQuota-debt {
			return 0, 0, ErrWalletQuotaOutOfRange
		}
		newDebt += shortfall
	}
	return
}

// Callers serialize on the invitee, then the inviter. The compare predicates
// also protect SQLite and concurrent affiliate-to-wallet transfers.
func appendReferralEntryTx(tx *gorm.DB, reward *ReferralReward, key, kind, reason string, delta, actorID int) error {
	if delta == 0 {
		return nil
	}
	var inviter User
	if err := lockForUpdate(tx).Unscoped().First(&inviter, reward.InviterID).Error; err != nil {
		return err
	}
	balance, debt, err := referralBalanceDelta(inviter.AffQuota, inviter.AffDebt, delta)
	if err != nil {
		return err
	}
	updates := map[string]interface{}{"aff_quota": balance, "aff_debt": debt}
	if kind == "reward" {
		if inviter.AffHistoryQuota < 0 || delta > common.MaxWalletQuota-inviter.AffHistoryQuota {
			return ErrWalletQuotaOutOfRange
		}
		updates["aff_history"] = inviter.AffHistoryQuota + delta
	}
	result := tx.Unscoped().Model(&User{}).
		Where("id = ? AND aff_quota = ? AND aff_debt = ?", inviter.Id, inviter.AffQuota, inviter.AffDebt).
		Updates(updates)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return ErrReferralConflict
	}
	return tx.Create(&ReferralLedgerEntry{
		InviterID: inviter.Id, InviteeID: reward.InviteeID, RewardID: reward.ID,
		OperationKey: key, Kind: kind, Reason: reason, QuotaDelta: delta,
		BalanceDelta: balance - inviter.AffQuota, DebtDelta: debt - inviter.AffDebt,
		BalanceAfter: balance, DebtAfter: debt, ActorID: actorID,
	}).Error
}

// Called only after verified settlement has updated the order and wallet,
// inside that same transaction. The user-row CAS makes concurrent *different*
// orders consume one first-payment eligibility, independent of process locks.
func grantFirstTopUpReferralTx(tx *gorm.DB, topUp *TopUp) error {
	if !referralCashTopUp(topUp) {
		return nil
	}
	var invitee User
	if err := lockForUpdate(tx).First(&invitee, topUp.UserId).Error; err != nil {
		return err
	}
	if !invitee.ReferralFirstTopUpEligible || invitee.InviterId <= 0 || invitee.InviterId == invitee.Id {
		return nil
	}
	claim := tx.Model(&User{}).Where("id = ? AND referral_first_top_up_eligible = ?", invitee.Id, true).
		Update("referral_first_top_up_eligible", false)
	if claim.Error != nil {
		return claim.Error
	}
	if claim.RowsAffected != 1 {
		return nil
	}

	policy := ReferralPolicySnapshot()
	rewardQuota, penaltyQuota := policy.amounts()
	reason := "first_paid_topup"
	var inviter User
	err := lockForUpdate(tx).Unscoped().First(&inviter, invitee.InviterId).Error
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}
	switch {
	case err != nil || inviter.DeletedAt.Valid || inviter.Status != common.UserStatusEnabled:
		reason = "inviter_unavailable"
	case invitee.Status != common.UserStatusEnabled || invitee.ReferralBanCaseID != 0:
		reason = "invitee_disabled"
	case !promotionRewardsAllowedForUser(&invitee) || !promotionRewardsAllowedForUser(&inviter):
		reason = "promotion_ineligible"
	case !operation_setting.IsPaymentComplianceConfirmed() || rewardQuota <= 0:
		reason = "rewards_disabled"
	case topUp.CreditedQuota < int64(policy.MinTopUpQuota):
		reason = "below_minimum"
	}
	if reason != "first_paid_topup" {
		rewardQuota, penaltyQuota = 0, 0
	}
	reward := ReferralReward{
		InviteeID: invitee.Id, InviterID: invitee.InviterId, TopUpID: topUp.Id,
		Quota: rewardQuota, PenaltyQuota: penaltyQuota, Reason: reason,
	}
	if err := tx.Create(&reward).Error; err != nil {
		return err
	}
	if err := appendReferralEntryTx(tx, &reward, fmt.Sprintf("reward:%d", reward.ID), "reward", reason, rewardQuota, 0); err != nil {
		return err
	}
	topUp.ReferralRewardID = reward.ID
	return tx.Model(&TopUp{}).Where("id = ?", topUp.Id).Update("referral_reward_id", reward.ID).Error
}

// Refunds reclaim proportionally using the immutable award. During a ban the
// award is already reclaimed, so only the refund baseline advances. An appeal
// restores at most the still-paid portion, never refunded value.
func reclaimRefundedReferralTx(tx *gorm.DB, topUp *TopUp, cumulativeRefund, paidMicros int64, eventKey string, actorID int) error {
	if topUp.ReferralRewardID == 0 {
		return nil
	}
	var invitee User
	if err := lockForUpdate(tx).First(&invitee, topUp.UserId).Error; err != nil {
		return err
	}
	var reward ReferralReward
	if err := lockForUpdate(tx).Where("id = ? AND top_up_id = ? AND invitee_id = ?", topUp.ReferralRewardID, topUp.Id, topUp.UserId).First(&reward).Error; err != nil {
		return err
	}
	target := int(proportionalRefundTarget(int64(reward.Quota), paidMicros, cumulativeRefund))
	if target < reward.RefundReclaimedQuota || target > reward.Quota {
		return ErrRefundAmountInvalid
	}
	delta := target - reward.RefundReclaimedQuota
	if reward.BanCaseID == 0 {
		if err := appendReferralEntryTx(tx, &reward, fmt.Sprintf("refund:%x", sha256.Sum256([]byte(eventKey))), "refund_reclaim", "payment_refund", -delta, actorID); err != nil {
			return err
		}
	}
	return tx.Model(&reward).Update("refund_reclaimed_quota", target).Error
}

func ListReferralLedger(userID int, beforeID uint, limit int) ([]ReferralLedgerEntry, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	items := make([]ReferralLedgerEntry, 0)
	query := DB.Where("inviter_id = ?", userID)
	if beforeID > 0 {
		query = query.Where("id < ?", beforeID)
	}
	err := query.Order("id DESC").Limit(limit).Find(&items).Error
	return items, err
}
