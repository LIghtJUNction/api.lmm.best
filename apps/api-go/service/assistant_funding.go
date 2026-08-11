package service

import (
	"errors"
	"fmt"

	"github.com/QuantumNous/new-api/model"
)

var ErrAssistantBalanceInsufficient = errors.New("super administrator balance is insufficient for AI assistant service")

// AssistantFunding charges every customer-service model call to the enabled
// super administrator selected by the controller.
type AssistantFunding struct {
	userId   int
	consumed int
}

func NewAssistantFunding(userId int) *AssistantFunding {
	return &AssistantFunding{userId: userId}
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
	if enforceWalletBalance {
		quota, err := model.GetUserQuota(a.userId, true)
		if err != nil {
			return err
		}
		if quota < amount {
			return fmt.Errorf("%w: remaining=%d required=%d", ErrAssistantBalanceInsufficient, quota, amount)
		}
	}
	if err := model.DecreaseUserQuota(a.userId, amount, true); err != nil {
		return err
	}
	a.consumed += amount
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
	return a.release(a.consumed)
}

func (a *AssistantFunding) RollbackReserve(amount int) error {
	return a.release(amount)
}

// release refunds quota to the same super-administrator wallet that funded
// the request.
func (a *AssistantFunding) release(amount int) error {
	if amount <= 0 {
		return nil
	}
	if amount > a.consumed {
		return fmt.Errorf("assistant funding refund exceeds consumption: refund=%d consumed=%d", amount, a.consumed)
	}
	if err := model.IncreaseUserQuota(a.userId, amount, true); err != nil {
		return err
	}
	a.consumed -= amount
	return nil
}
