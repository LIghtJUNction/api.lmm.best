package model

import (
	"errors"
	"fmt"
	"sync"
	"testing"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/setting/operation_setting"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func setupReferralDB(t *testing.T) (*gorm.DB, User, User, User) {
	t.Helper()
	db := setupExternalTopUpSettlementDB(t, 8)
	require.NoError(t, db.AutoMigrate(&ReferralReward{}, &ReferralLedgerEntry{}, &ReferralBanCase{}, &UserSession{}, &FinanceLedgerEntry{}))
	oldRedis, oldUnit := common.RedisEnabled, common.QuotaPerUnit
	common.RedisEnabled, common.QuotaPerUnit = false, 1
	payment := operation_setting.GetPaymentSetting()
	oldCompliance, oldTerms := payment.ComplianceConfirmed, payment.ComplianceTermsVersion
	payment.ComplianceConfirmed, payment.ComplianceTermsVersion = true, operation_setting.CurrentComplianceTermsVersion
	common.OptionMapRWMutex.Lock()
	oldOptions := common.OptionMap
	common.OptionMap = map[string]string{"QuotaForInviter": "100", ReferralPenaltyPercentOption: "20"}
	common.OptionMapRWMutex.Unlock()
	t.Cleanup(func() {
		common.RedisEnabled, common.QuotaPerUnit = oldRedis, oldUnit
		payment.ComplianceConfirmed, payment.ComplianceTermsVersion = oldCompliance, oldTerms
		common.OptionMapRWMutex.Lock()
		common.OptionMap = oldOptions
		common.OptionMapRWMutex.Unlock()
	})
	inviter := User{Username: "referrer", AffCode: "referrer-code", Email: "inviter@example.com", Status: common.UserStatusEnabled, Role: common.RoleCommonUser, Quota: 500}
	admin := User{Username: "reviewer", AffCode: "reviewer-code", Status: common.UserStatusEnabled, Role: common.RoleRootUser}
	require.NoError(t, db.Create(&inviter).Error)
	require.NoError(t, db.Create(&admin).Error)
	invitee := User{Username: "invitee", AffCode: "invitee-code", Email: "invitee@example.com", Status: common.UserStatusEnabled, Role: common.RoleCommonUser}
	require.NoError(t, db.Transaction(func(tx *gorm.DB) error { return createUserWithReferralTx(tx, &invitee, inviter.Id) }))
	return db, inviter, invitee, admin
}

func referralPayment(t *testing.T, db *gorm.DB, userID int, trade string) (TopUp, ExternalTopUpSettlement) {
	t.Helper()
	order := TopUp{UserId: userID, TradeNo: trade, CreditedQuota: 1000, ExpectedAmountMicros: 1_000_000,
		Money: 1, SettlementCurrency: "USD", PaymentProvider: PaymentProviderStripe, PaymentMethod: PaymentMethodStripe, Status: common.TopUpStatusPending}
	require.NoError(t, db.Create(&order).Error)
	return order, ExternalTopUpSettlement{TradeNo: trade, PaymentProvider: PaymentProviderStripe, PaymentMethod: PaymentMethodStripe,
		SettlementCurrency: "USD", SettledAmountMicros: 1_000_000, ProviderEventId: "evt-" + trade, ProviderTransactionId: "txn-" + trade}
}

func referralUser(t *testing.T, db *gorm.DB, id int) User {
	t.Helper()
	var user User
	require.NoError(t, db.First(&user, id).Error)
	return user
}

func referralBanInput(invitee, admin User, penalize bool) ReferralBanInput {
	return ReferralBanInput{UserID: invitee.Id, ActorID: admin.Id, RequestID: "verified-case-001", Reason: "bulk_registration", Evidence: "Confirmed linked batch registration and payment evidence", PenalizeInviter: penalize}
}

func TestReferralFirstPaidTopUpOnlyAndDuplicateCallbacks(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota, "registration must not award the inviter")
	assert.Equal(t, 1, referralUser(t, db, inviter.Id).AffCount)
	_, settlement := referralPayment(t, db, invitee.Id, "first")
	for range 3 {
		_, err := CompleteExternalTopUp(settlement)
		require.NoError(t, err)
	}
	_, later := referralPayment(t, db, invitee.Id, "later")
	_, err := CompleteExternalTopUp(later)
	require.NoError(t, err)
	stored := referralUser(t, db, inviter.Id)
	assert.Equal(t, 100, stored.AffQuota)
	assert.Equal(t, 100, stored.AffHistoryQuota)
	assert.Zero(t, stored.AffDebt)
	assert.Equal(t, 500, stored.Quota, "paid wallet must stay separate")
	assert.False(t, referralUser(t, db, invitee.Id).ReferralFirstTopUpEligible)
	var count int64
	require.NoError(t, db.Model(&ReferralReward{}).Count(&count).Error)
	assert.EqualValues(t, 1, count)
	entries, err := ListReferralLedger(inviter.Id, 0, 20)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, 100, entries[0].QuotaDelta)
}

func TestReferralDifferentConcurrentPaymentsAwardOnce(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	_, a := referralPayment(t, db, invitee.Id, "concurrent-a")
	_, b := referralPayment(t, db, invitee.Id, "concurrent-b")
	start := make(chan struct{})
	errorsCh := make(chan error, 2)
	var wg sync.WaitGroup
	for _, settlement := range []ExternalTopUpSettlement{a, b} {
		wg.Add(1)
		go func(s ExternalTopUpSettlement) {
			defer wg.Done()
			<-start
			_, err := completeExternalTopUpOnDB(db.Session(&gorm.Session{NewDB: true}), s)
			errorsCh <- err
		}(settlement)
	}
	close(start)
	wg.Wait()
	close(errorsCh)
	for err := range errorsCh {
		require.NoError(t, err)
	}
	assert.Equal(t, 100, referralUser(t, db, inviter.Id).AffQuota)
	assert.Equal(t, 2000, referralUser(t, db, invitee.Id).Quota)
}

func TestReferralAwardFailureRollsBackSettlementAndEligibility(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	order, settlement := referralPayment(t, db, invitee.Id, "rollback")
	injected := errors.New("injected ledger failure")
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("test:referral_failure", func(tx *gorm.DB) {
		if tx.Statement.Schema != nil && tx.Statement.Schema.Name == "ReferralLedgerEntry" {
			tx.AddError(injected)
		}
	}))
	_, err := CompleteExternalTopUp(settlement)
	require.ErrorIs(t, err, injected)
	require.NoError(t, db.Callback().Create().Remove("test:referral_failure"))
	assert.True(t, referralUser(t, db, invitee.Id).ReferralFirstTopUpEligible)
	assert.Zero(t, referralUser(t, db, invitee.Id).Quota)
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
	require.NoError(t, db.First(&order, order.Id).Error)
	assert.Equal(t, common.TopUpStatusPending, order.Status)
	_, err = CompleteExternalTopUp(settlement)
	require.NoError(t, err)
	assert.Equal(t, 100, referralUser(t, db, inviter.Id).AffQuota)
}

func TestReferralNonCashSourcesCannotConsumeFirstPayment(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	for _, method := range []string{"balance", "gift", "bonus", "checkin", "invite", "bounty", "admin", "ldc"} {
		order := TopUp{UserId: invitee.Id, Status: common.TopUpStatusSuccess, CreditedQuota: 1000, SettledAmountMicros: 1_000_000,
			PaymentProvider: PaymentProviderEpay, PaymentMethod: method, SettlementCurrency: "CNY"}
		require.NoError(t, db.Transaction(func(tx *gorm.DB) error { return grantFirstTopUpReferralTx(tx, &order) }))
		assert.True(t, referralUser(t, db, invitee.Id).ReferralFirstTopUpEligible, method)
	}
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
}

func TestReferralThresholdAndDisabledPolicyConsumeFirstPayment(t *testing.T) {
	for _, test := range []struct{ key, value, reason string }{
		{ReferralMinTopUpQuotaOption, "1001", "below_minimum"}, {"QuotaForInviter", "0", "rewards_disabled"},
	} {
		t.Run(test.reason, func(t *testing.T) {
			db, inviter, invitee, _ := setupReferralDB(t)
			common.OptionMapRWMutex.Lock()
			common.OptionMap[test.key] = test.value
			common.OptionMapRWMutex.Unlock()
			_, first := referralPayment(t, db, invitee.Id, "threshold")
			_, err := CompleteExternalTopUp(first)
			require.NoError(t, err)
			var reward ReferralReward
			require.NoError(t, db.Where("invitee_id = ?", invitee.Id).First(&reward).Error)
			assert.Equal(t, test.reason, reward.Reason)
			assert.Zero(t, reward.Quota)
			common.OptionMapRWMutex.Lock()
			common.OptionMap["QuotaForInviter"] = "100"
			common.OptionMap[ReferralMinTopUpQuotaOption] = "0"
			common.OptionMapRWMutex.Unlock()
			_, later := referralPayment(t, db, invitee.Id, "after-policy-change")
			_, err = CompleteExternalTopUp(later)
			require.NoError(t, err)
			assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
		})
	}
}

func TestReferralLegacyRegistrationDoesNotReceiveAnotherBonus(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	require.NoError(t, db.Model(&User{}).Where("id = ?", invitee.Id).Update("referral_first_top_up_eligible", false).Error)
	_, settlement := referralPayment(t, db, invitee.Id, "legacy")
	_, err := CompleteExternalTopUp(settlement)
	require.NoError(t, err)
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
}

func TestReferralBanReclaimsAndPenalizesOnceWithoutTouchingPaidWallet(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	_, settlement := referralPayment(t, db, invitee.Id, "ban")
	_, err := CompleteExternalTopUp(settlement)
	require.NoError(t, err)
	inviter = referralUser(t, db, inviter.Id)
	require.NoError(t, inviter.TransferAffQuotaToQuota(100))
	input := referralBanInput(invitee, admin, true)
	first, err := BanReferralInvitee(input)
	require.NoError(t, err)
	replay, err := BanReferralInvitee(input)
	require.NoError(t, err)
	assert.Equal(t, first.ID, replay.ID)
	assert.Equal(t, 100, first.ReclaimedQuota)
	assert.Equal(t, 20, first.PenaltyQuota)
	stored := referralUser(t, db, inviter.Id)
	assert.Zero(t, stored.AffQuota)
	assert.Equal(t, 120, stored.AffDebt)
	assert.Equal(t, 600, stored.Quota, "do not subtract paid/transferred wallet credit")
	assert.Equal(t, common.UserStatusDisabled, referralUser(t, db, invitee.Id).Status)
	assert.Equal(t, first.ID, referralUser(t, db, invitee.Id).ReferralBanCaseID)
	input.RequestID = "different-case-id"
	_, err = BanReferralInvitee(input)
	require.ErrorIs(t, err, ErrReferralBanActive)
	assert.Equal(t, 120, referralUser(t, db, inviter.Id).AffDebt)
	entries, err := ListReferralLedger(inviter.Id, 0, 20)
	require.NoError(t, err)
	assert.Len(t, entries, 3)
}

func TestReferralBanWithoutPenaltyAndMisbanRestoration(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	_, settlement := referralPayment(t, db, invitee.Id, "appeal")
	_, err := CompleteExternalTopUp(settlement)
	require.NoError(t, err)
	input := referralBanInput(invitee, admin, false)
	ban, err := BanReferralInvitee(input)
	require.NoError(t, err)
	assert.Zero(t, ban.PenaltyQuota)
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
	for range 2 {
		_, err = RestoreReferralBan(ban.ID, invitee.Id, admin.Id, "Investigation confirms a false positive")
		require.NoError(t, err)
	}
	assert.Equal(t, 100, referralUser(t, db, inviter.Id).AffQuota)
	assert.Equal(t, common.UserStatusEnabled, referralUser(t, db, invitee.Id).Status)
	_, err = BanReferralInvitee(input)
	require.NoError(t, err)
	assert.Equal(t, common.UserStatusEnabled, referralUser(t, db, invitee.Id).Status, "old request replay must not re-ban")
	assert.False(t, referralUser(t, db, invitee.Id).ReferralFirstTopUpEligible)
}

func TestReferralFutureAwardsRepayDebtFirst(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	_, s := referralPayment(t, db, invitee.Id, "debt-first")
	_, err := CompleteExternalTopUp(s)
	require.NoError(t, err)
	_, err = BanReferralInvitee(referralBanInput(invitee, admin, true))
	require.NoError(t, err)
	assert.Equal(t, 20, referralUser(t, db, inviter.Id).AffDebt)
	second := User{Username: "second-invitee", AffCode: "second-code", Status: common.UserStatusEnabled}
	require.NoError(t, db.Transaction(func(tx *gorm.DB) error { return createUserWithReferralTx(tx, &second, inviter.Id) }))
	_, s = referralPayment(t, db, second.Id, "debt-second")
	_, err = CompleteExternalTopUp(s)
	require.NoError(t, err)
	stored := referralUser(t, db, inviter.Id)
	assert.Zero(t, stored.AffDebt)
	assert.Equal(t, 80, stored.AffQuota)
	entries, err := ListReferralLedger(inviter.Id, 0, 1)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, -20, entries[0].DebtDelta)
	assert.Equal(t, 80, entries[0].BalanceDelta)
}

func TestReferralRefundDuringBanIsNotRestoredOnAppeal(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	_, s := referralPayment(t, db, invitee.Id, "refund-appeal")
	_, err := CompleteExternalTopUp(s)
	require.NoError(t, err)
	ban, err := BanReferralInvitee(referralBanInput(invitee, admin, true))
	require.NoError(t, err)
	for range 2 {
		_, err = ApplyPaymentRefund(s.TradeNo, false, 250_000, "USD", "partial-refund", PaymentMethodStripe, PaymentProviderStripe, "verified refund", admin.Id)
		require.NoError(t, err)
	}
	_, err = RestoreReferralBan(ban.ID, invitee.Id, admin.Id, "False positive confirmed by payment records")
	require.NoError(t, err)
	stored := referralUser(t, db, inviter.Id)
	assert.Equal(t, 75, stored.AffQuota)
	assert.Zero(t, stored.AffDebt)
	assert.Equal(t, 750, referralUser(t, db, invitee.Id).Quota)
	var reward ReferralReward
	require.NoError(t, db.Where("invitee_id = ?", invitee.Id).First(&reward).Error)
	assert.Equal(t, 25, reward.RefundReclaimedQuota)
}

func TestReferralFullRefundReclaimsWithoutPenaltyOrRenewedEligibility(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	_, s := referralPayment(t, db, invitee.Id, "full-refund")
	_, err := CompleteExternalTopUp(s)
	require.NoError(t, err)
	_, err = ApplyPaymentRefund(s.TradeNo, false, 1_000_000, "USD", "full-refund-event", PaymentMethodStripe, PaymentProviderStripe, "verified refund", admin.Id)
	require.NoError(t, err)
	stored := referralUser(t, db, inviter.Id)
	assert.Zero(t, stored.AffQuota)
	assert.Zero(t, stored.AffDebt)
	_, s = referralPayment(t, db, invitee.Id, "after-refund")
	_, err = CompleteExternalTopUp(s)
	require.NoError(t, err)
	assert.Zero(t, referralUser(t, db, inviter.Id).AffQuota)
}

func TestReferralOrdinaryDisableDoesNotReclaim(t *testing.T) {
	db, inviter, invitee, _ := setupReferralDB(t)
	_, s := referralPayment(t, db, invitee.Id, "ordinary-disable")
	_, err := CompleteExternalTopUp(s)
	require.NoError(t, err)
	invitee = referralUser(t, db, invitee.Id)
	invitee.Status = common.UserStatusDisabled
	require.NoError(t, invitee.Update(false))
	assert.Equal(t, 100, referralUser(t, db, inviter.Id).AffQuota)
}

func TestReferralImmutableBindingAndEligibility(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	stale := invitee
	_, s := referralPayment(t, db, invitee.Id, "immutable")
	_, err := CompleteExternalTopUp(s)
	require.NoError(t, err)
	stale.InviterId = admin.Id
	stale.AffDebt = 500
	stale.ReferralFirstTopUpEligible = true
	require.NoError(t, stale.Update(false))
	stored := referralUser(t, db, invitee.Id)
	assert.Equal(t, inviter.Id, stored.InviterId)
	assert.False(t, stored.ReferralFirstTopUpEligible)
	assert.Zero(t, stored.AffDebt)
	ban, err := BanReferralInvitee(referralBanInput(invitee, admin, false))
	require.NoError(t, err)
	stored = referralUser(t, db, invitee.Id)
	stored.Status = common.UserStatusEnabled
	require.ErrorIs(t, stored.Update(false), ErrReferralBanActive)
	assert.Equal(t, ban.ID, referralUser(t, db, invitee.Id).ReferralBanCaseID)
}

func TestReferralEnforcementRejectsInvalidReasonAndUnprivilegedActor(t *testing.T) {
	db, inviter, invitee, admin := setupReferralDB(t)
	input := referralBanInput(invitee, admin, true)
	input.Reason = "same_ip_only"
	_, err := BanReferralInvitee(input)
	require.ErrorIs(t, err, gorm.ErrInvalidData)
	input.Reason = "abuse"
	input.ActorID = inviter.Id
	_, err = BanReferralInvitee(input)
	require.ErrorIs(t, err, ErrReferralPermission)
	assert.Equal(t, common.UserStatusEnabled, referralUser(t, db, invitee.Id).Status)
	input.ActorID = admin.Id
	input.Evidence = ""
	_, err = BanReferralInvitee(input)
	require.ErrorIs(t, err, gorm.ErrInvalidData)
}

func TestReferralSnapshotCapsAndSafeIntegerArithmetic(t *testing.T) {
	p := ReferralPolicy{RewardQuota: 1000, RewardCapQuota: 101, PenaltyPercent: 20, PenaltyCapQuota: 15}
	reward, penalty := p.amounts()
	assert.Equal(t, 101, reward)
	assert.Equal(t, 15, penalty)
	p = ReferralPolicy{RewardQuota: common.MaxWalletQuota, PenaltyPercent: 100}
	reward, penalty = p.amounts()
	assert.Equal(t, reward, penalty)
	for _, value := range []string{"-1", "1.5", "NaN", "1e309", fmt.Sprint(common.MaxWalletQuota + 1)} {
		require.Error(t, validateReferralOption(ReferralRewardCapQuotaOption, value), value)
	}
	require.Error(t, validateReferralOption(ReferralPenaltyPercentOption, "101"))
	require.NoError(t, validateReferralOption(ReferralPenaltyPercentOption, "0"))
	_, _, err := referralBalanceDelta(common.MaxWalletQuota, 0, 1)
	require.Error(t, err)
	_, _, err = referralBalanceDelta(0, common.MaxWalletQuota, -1)
	require.Error(t, err)
	_, _, err = referralBalanceDelta(1, 1, 0)
	require.Error(t, err)
	balance, debt, err := referralBalanceDelta(0, 120, 100)
	require.NoError(t, err)
	assert.Zero(t, balance)
	assert.Equal(t, 20, debt)
}
