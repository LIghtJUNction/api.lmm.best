package service

import (
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting"
)

var ErrAssistantBalanceInsufficient = errors.New("assistant balance is insufficient after weekly credit")

type AssistantCreditStatus struct {
	WeeklyCreditUSD float64 `json:"weekly_credit_usd"`
	LimitQuota      int     `json:"limit_quota"`
	UsedQuota       int     `json:"used_quota"`
	RemainingQuota  int     `json:"remaining_quota"`
	WeekStart       int64   `json:"week_start"`
	ResetsAt        int64   `json:"resets_at"`
}

func assistantWeeklyQuotaLimit() int {
	creditUSD := setting.GetAssistantSettings().WeeklyCreditUSD
	quota := creditUSD * common.QuotaPerUnit
	if math.IsNaN(quota) || quota <= 0 {
		return 0
	}
	if math.IsInf(quota, 1) || quota >= float64(math.MaxInt) {
		return math.MaxInt
	}
	return int(math.Round(quota))
}

func GetAssistantCreditStatus(userId int, now time.Time) (AssistantCreditStatus, error) {
	settings := setting.GetAssistantSettings()
	weekStart := model.AssistantWeekStartUTC(now)
	limit := assistantWeeklyQuotaLimit()
	used, err := model.GetAssistantWeeklyUsage(userId, weekStart)
	if err != nil {
		return AssistantCreditStatus{}, err
	}
	remaining := int64(limit) - used
	if remaining < 0 {
		remaining = 0
	}
	return AssistantCreditStatus{
		WeeklyCreditUSD: settings.WeeklyCreditUSD,
		LimitQuota:      limit,
		UsedQuota:       int(used),
		RemainingQuota:  int(remaining),
		WeekStart:       weekStart,
		ResetsAt:        weekStart + int64(7*24*time.Hour/time.Second),
	}, nil
}

// AssistantFunding consumes the weekly system-funded allowance first and
// charges only the remainder to the user's wallet.
type AssistantFunding struct {
	userId         int
	weekStart      int64
	weeklyLimit    int64
	creditConsumed int
	walletConsumed int
}

func NewAssistantFunding(userId int, weekStart int64, weeklyLimit int) *AssistantFunding {
	return &AssistantFunding{
		userId:      userId,
		weekStart:   weekStart,
		weeklyLimit: int64(weeklyLimit),
	}
}

func (a *AssistantFunding) Source() string { return BillingSourceAssistant }

func (a *AssistantFunding) PreConsume(amount int) error {
	return a.reserve(amount, true)
}

func (a *AssistantFunding) Reserve(amount int) error {
	return a.reserve(amount, true)
}

func (a *AssistantFunding) reserve(amount int, enforceWalletBalance bool) error {
	if amount <= 0 {
		return nil
	}
	credit, err := model.ReserveAssistantWeeklyCredit(a.userId, a.weekStart, a.weeklyLimit, amount)
	if err != nil {
		return err
	}
	wallet := amount - credit
	if wallet > 0 && enforceWalletBalance {
		quota, quotaErr := model.GetUserQuota(a.userId, true)
		if quotaErr != nil {
			_ = model.RefundAssistantWeeklyCredit(a.userId, a.weekStart, credit)
			return quotaErr
		}
		if quota < wallet {
			_ = model.RefundAssistantWeeklyCredit(a.userId, a.weekStart, credit)
			return fmt.Errorf("%w: remaining=%d required=%d", ErrAssistantBalanceInsufficient, quota, wallet)
		}
	}
	if wallet > 0 {
		if err := model.DecreaseUserQuota(a.userId, wallet, true); err != nil {
			_ = model.RefundAssistantWeeklyCredit(a.userId, a.weekStart, credit)
			return err
		}
	}
	a.creditConsumed += credit
	a.walletConsumed += wallet
	return nil
}

func (a *AssistantFunding) Settle(delta int) error {
	if delta > 0 {
		// Post-settlement follows normal relay semantics and records overage even
		// when the wallet crosses zero, rather than dropping already-served usage.
		return a.reserve(delta, false)
	}
	if delta < 0 {
		return a.release(-delta)
	}
	return nil
}

func (a *AssistantFunding) Refund() error {
	return a.release(a.creditConsumed + a.walletConsumed)
}

func (a *AssistantFunding) RollbackReserve(amount int) error {
	return a.release(amount)
}

// release refunds wallet-funded quota first so the final settled request uses
// as much of the free weekly allowance as possible.
func (a *AssistantFunding) release(amount int) error {
	if amount <= 0 {
		return nil
	}
	consumed := a.creditConsumed + a.walletConsumed
	if amount > consumed {
		return fmt.Errorf("assistant funding refund exceeds consumption: refund=%d consumed=%d", amount, consumed)
	}

	walletRefund := amount
	if walletRefund > a.walletConsumed {
		walletRefund = a.walletConsumed
	}
	if walletRefund > 0 {
		if err := model.IncreaseUserQuota(a.userId, walletRefund, true); err != nil {
			return err
		}
		a.walletConsumed -= walletRefund
	}

	creditRefund := amount - walletRefund
	if creditRefund > 0 {
		if err := model.RefundAssistantWeeklyCredit(a.userId, a.weekStart, creditRefund); err != nil {
			// Restore the wallet charge when the second half of the refund fails.
			if walletRefund > 0 {
				if rollbackErr := model.DecreaseUserQuota(a.userId, walletRefund, true); rollbackErr == nil {
					a.walletConsumed += walletRefund
				}
			}
			return err
		}
		a.creditConsumed -= creditRefund
	}
	return nil
}
