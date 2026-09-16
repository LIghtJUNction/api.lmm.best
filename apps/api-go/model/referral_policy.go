package model

import (
	"errors"
	"strconv"

	"github.com/LIghtJUNction/api.lmm.best/common"
)

const (
	ReferralMinTopUpQuotaOption   = "ReferralMinTopUpQuota"
	ReferralRewardCapQuotaOption  = "ReferralRewardCapQuota"
	ReferralPenaltyPercentOption  = "ReferralPenaltyPercent"
	ReferralPenaltyCapQuotaOption = "ReferralPenaltyCapQuota"
)

var referralOptionDefaults = map[string]string{
	ReferralMinTopUpQuotaOption:   "0",
	ReferralRewardCapQuotaOption:  "0",
	ReferralPenaltyPercentOption:  "20",
	ReferralPenaltyCapQuotaOption: "0",
}

// Thresholds are platform quota units, never a mixture of gateway currencies.
// A zero reward disables awards; a zero cap means no additional cap.
type ReferralPolicy struct {
	RewardQuota     int `json:"reward_quota"`
	MinTopUpQuota   int `json:"min_topup_quota"`
	RewardCapQuota  int `json:"reward_cap_quota"`
	PenaltyPercent  int `json:"penalty_percent"`
	PenaltyCapQuota int `json:"penalty_cap_quota"`
}

func validateReferralOption(key, value string) error {
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < 0 || n > int64(common.MaxWalletQuota) {
		return errors.New("referral quota must be a non-negative safe integer")
	}
	if key == ReferralPenaltyPercentOption && n > 100 {
		return errors.New("referral penalty percent must be between 0 and 100")
	}
	return nil
}

func ReferralPolicySnapshot() ReferralPolicy {
	common.OptionMapRWMutex.RLock()
	defer common.OptionMapRWMutex.RUnlock()
	read := func(key, fallback string) int {
		value, ok := common.OptionMap[key]
		if !ok {
			value = fallback
		}
		if validateReferralOption(key, value) != nil {
			return 0
		}
		n, _ := strconv.Atoi(value)
		return n
	}
	return ReferralPolicy{
		RewardQuota:     read("QuotaForInviter", "0"),
		MinTopUpQuota:   read(ReferralMinTopUpQuotaOption, "0"),
		RewardCapQuota:  read(ReferralRewardCapQuotaOption, "0"),
		PenaltyPercent:  read(ReferralPenaltyPercentOption, "20"),
		PenaltyCapQuota: read(ReferralPenaltyCapQuotaOption, "0"),
	}
}

func (p ReferralPolicy) amounts() (reward, penalty int) {
	reward = p.RewardQuota
	if p.RewardCapQuota > 0 && reward > p.RewardCapQuota {
		reward = p.RewardCapQuota
	}
	// Divide before multiplying: MaxWalletQuota * 100 can overflow int64.
	penalty = (reward/100)*p.PenaltyPercent + ((reward%100)*p.PenaltyPercent+99)/100
	if p.PenaltyCapQuota > 0 && penalty > p.PenaltyCapQuota {
		penalty = p.PenaltyCapQuota
	}
	return
}
