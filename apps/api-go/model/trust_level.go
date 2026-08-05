package model

import (
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
	"gorm.io/gorm"
)

const (
	TrustLevelMinUser = 0
	TrustLevelMaxUser = 4
	TrustLevelAdmin   = 5
	TrustLevelRoot    = 6

	trustLevelDecayPeriod = 90 * 24 * time.Hour
	trustAggregateTTL     = time.Minute
)

var trustLevelThresholds = [...]float64{0, 10, 100, 500, 2000}
var trustLevelDiscountRatios = [...]float64{1, 1, 0.97, 0.94, 0.90}

type TrustLevelInfo struct {
	Level                int      `json:"level"`
	AutomaticLevel       int      `json:"automatic_level"`
	OverrideLevel        *int     `json:"override_level"`
	PaidAmount           float64  `json:"paid_amount"`
	DiscountRatio        float64  `json:"discount_ratio"`
	DiscountPercent      float64  `json:"discount_percent"`
	NextLevel            *int     `json:"next_level"`
	NextLevelPaidAmount  *float64 `json:"next_level_paid_amount"`
	AmountToNextLevel    *float64 `json:"amount_to_next_level"`
	NextDecayAt          *int64   `json:"next_decay_at"`
	InactivityDecaySteps int      `json:"inactivity_decay_steps"`
	Overridden           bool     `json:"overridden"`
}

type paidTopUpAggregate struct {
	PaidAmount         float64
	LastPaidCompleteAt int64
}

type paidTopUpAggregateRow struct {
	UserID             int   `gorm:"column:user_id"`
	PaidQuota          int64 `gorm:"column:paid_quota"`
	LastPaidCompleteAt int64 `gorm:"column:last_paid_complete_at"`
}

type cachedPaidTopUpAggregate struct {
	value     paidTopUpAggregate
	expiresAt time.Time
}

var paidTopUpAggregateCache = struct {
	sync.RWMutex
	values map[int]cachedPaidTopUpAggregate
}{values: make(map[int]cachedPaidTopUpAggregate)}

func automaticTrustLevel(paidAmount float64) int {
	for level := TrustLevelMaxUser; level >= TrustLevelMinUser; level-- {
		if paidAmount >= trustLevelThresholds[level] {
			return level
		}
	}
	return TrustLevelMinUser
}

func EvaluateTrustLevel(role int, overrideLevel *int, paidAmount float64, activityAnchor int64, now int64) TrustLevelInfo {
	if now <= 0 {
		now = time.Now().Unix()
	}
	if role == common.RoleRootUser {
		return administratorTrustLevelInfo(TrustLevelRoot)
	}
	if role >= common.RoleAdminUser {
		return administratorTrustLevelInfo(TrustLevelAdmin)
	}

	automaticLevel := automaticTrustLevel(paidAmount)
	effectiveLevel := automaticLevel
	decaySteps := 0
	var nextDecayAt *int64
	if automaticLevel > 0 && activityAnchor > 0 && now > activityAnchor {
		periodSeconds := int64(trustLevelDecayPeriod / time.Second)
		decaySteps = int((now - activityAnchor) / periodSeconds)
		if decaySteps > automaticLevel {
			decaySteps = automaticLevel
		}
		effectiveLevel = automaticLevel - decaySteps
		if effectiveLevel > 0 {
			value := activityAnchor + int64(decaySteps+1)*periodSeconds
			nextDecayAt = &value
		}
	}

	overridden := overrideLevel != nil && *overrideLevel >= TrustLevelMinUser && *overrideLevel <= TrustLevelMaxUser
	if overridden {
		effectiveLevel = *overrideLevel
		nextDecayAt = nil
	}

	info := TrustLevelInfo{
		Level:                effectiveLevel,
		AutomaticLevel:       automaticLevel,
		OverrideLevel:        overrideLevel,
		PaidAmount:           paidAmount,
		DiscountRatio:        trustLevelDiscountRatios[effectiveLevel],
		DiscountPercent:      (1 - trustLevelDiscountRatios[effectiveLevel]) * 100,
		NextDecayAt:          nextDecayAt,
		InactivityDecaySteps: decaySteps,
		Overridden:           overridden,
	}
	if automaticLevel < TrustLevelMaxUser {
		next := automaticLevel + 1
		threshold := trustLevelThresholds[next]
		remaining := threshold - paidAmount
		if remaining < 0 {
			remaining = 0
		}
		info.NextLevel = &next
		info.NextLevelPaidAmount = &threshold
		info.AmountToNextLevel = &remaining
	}
	return info
}

func administratorTrustLevelInfo(level int) TrustLevelInfo {
	return TrustLevelInfo{
		Level:           level,
		AutomaticLevel:  level,
		DiscountRatio:   trustLevelDiscountRatios[TrustLevelMaxUser],
		DiscountPercent: (1 - trustLevelDiscountRatios[TrustLevelMaxUser]) * 100,
	}
}

func getPaidTopUpAggregate(userID int) (paidTopUpAggregate, error) {
	if userID <= 0 {
		return paidTopUpAggregate{}, nil
	}
	aggregates, err := getPaidTopUpAggregates([]int{userID})
	if err != nil {
		return paidTopUpAggregate{}, err
	}
	return aggregates[userID], nil
}

func getPaidTopUpAggregates(userIDs []int) (map[int]paidTopUpAggregate, error) {
	result := make(map[int]paidTopUpAggregate, len(userIDs))
	missing := make([]int, 0, len(userIDs))
	seen := make(map[int]struct{}, len(userIDs))
	now := time.Now()

	paidTopUpAggregateCache.RLock()
	for _, userID := range userIDs {
		if userID <= 0 {
			continue
		}
		if _, ok := seen[userID]; ok {
			continue
		}
		seen[userID] = struct{}{}
		if cached, ok := paidTopUpAggregateCache.values[userID]; ok && now.Before(cached.expiresAt) {
			result[userID] = cached.value
			continue
		}
		missing = append(missing, userID)
	}
	paidTopUpAggregateCache.RUnlock()

	if len(missing) == 0 {
		return result, nil
	}
	if DB == nil {
		return nil, gorm.ErrInvalidDB
	}

	var rows []paidTopUpAggregateRow
	if err := DB.Model(&TopUp{}).
		Select("user_id, COALESCE(SUM(amount), 0) AS paid_quota, COALESCE(MAX(complete_time), 0) AS last_paid_complete_at").
		Where("user_id IN ? AND status = ? AND amount > 0 AND money > 0", missing, common.TopUpStatusSuccess).
		Where("(payment_method IS NULL OR payment_method <> ?)", PaymentMethodBalance).
		Where("(payment_provider IS NULL OR payment_provider <> ?)", PaymentProviderBalance).
		Group("user_id").
		Scan(&rows).Error; err != nil {
		return nil, err
	}

	rowsByUserID := make(map[int]paidTopUpAggregateRow, len(rows))
	for _, row := range rows {
		rowsByUserID[row.UserID] = row
	}
	paidTopUpAggregateCache.Lock()
	for _, userID := range missing {
		row := rowsByUserID[userID]
		aggregate := paidTopUpAggregate{
			PaidAmount:         float64(row.PaidQuota) / float64(common.QuotaPerUnit),
			LastPaidCompleteAt: row.LastPaidCompleteAt,
		}
		result[userID] = aggregate
		paidTopUpAggregateCache.values[userID] = cachedPaidTopUpAggregate{
			value:     aggregate,
			expiresAt: now.Add(trustAggregateTTL),
		}
	}
	paidTopUpAggregateCache.Unlock()
	return result, nil
}

func invalidatePaidTopUpAggregate(userID int) {
	paidTopUpAggregateCache.Lock()
	delete(paidTopUpAggregateCache.values, userID)
	paidTopUpAggregateCache.Unlock()
}

func (topUp *TopUp) AfterSave(_ *gorm.DB) error {
	if topUp != nil && topUp.UserId > 0 {
		invalidatePaidTopUpAggregate(topUp.UserId)
	}
	return nil
}

func trustActivityAnchor(createdAt int64, lastAPIActivityAt int64, lastPaidCompleteAt int64) int64 {
	anchor := createdAt
	if lastAPIActivityAt > anchor {
		anchor = lastAPIActivityAt
	}
	if lastPaidCompleteAt > anchor {
		anchor = lastPaidCompleteAt
	}
	return anchor
}

func GetTrustLevelInfoForUser(user *User) (TrustLevelInfo, error) {
	if user == nil {
		return TrustLevelInfo{}, gorm.ErrInvalidData
	}
	if user.Role >= common.RoleAdminUser {
		return EvaluateTrustLevel(user.Role, nil, 0, 0, time.Now().Unix()), nil
	}
	aggregate, err := getPaidTopUpAggregate(user.Id)
	if err != nil {
		return TrustLevelInfo{}, err
	}
	anchor := trustActivityAnchor(user.CreatedAt, user.LastAPIActivityAt, aggregate.LastPaidCompleteAt)
	return EvaluateTrustLevel(user.Role, user.TrustLevelOverride, aggregate.PaidAmount, anchor, time.Now().Unix()), nil
}

func GetTrustLevelInfoForUserBase(user *UserBase) (TrustLevelInfo, error) {
	if user == nil {
		return TrustLevelInfo{}, gorm.ErrInvalidData
	}
	if user.Role >= common.RoleAdminUser {
		return EvaluateTrustLevel(user.Role, nil, 0, 0, time.Now().Unix()), nil
	}
	aggregate, err := getPaidTopUpAggregate(user.Id)
	if err != nil {
		return TrustLevelInfo{}, err
	}
	anchor := trustActivityAnchor(user.CreatedAt, user.LastAPIActivityAt, aggregate.LastPaidCompleteAt)
	return EvaluateTrustLevel(user.Role, user.TrustLevelOverride, aggregate.PaidAmount, anchor, time.Now().Unix()), nil
}

func GetTrustLevelInfoByUserID(userID int) (TrustLevelInfo, error) {
	user, err := GetUserCache(userID)
	if err != nil {
		return TrustLevelInfo{}, err
	}
	return GetTrustLevelInfoForUserBase(user)
}

func EnrichUsersTrustLevels(users []*User) error {
	userIDs := make([]int, 0, len(users))
	for _, user := range users {
		if user != nil && user.Role < common.RoleAdminUser {
			userIDs = append(userIDs, user.Id)
		}
	}
	aggregates, err := getPaidTopUpAggregates(userIDs)
	if err != nil {
		return err
	}
	now := time.Now().Unix()
	for _, user := range users {
		if user == nil {
			continue
		}
		var info TrustLevelInfo
		if user.Role >= common.RoleAdminUser {
			info = EvaluateTrustLevel(user.Role, nil, 0, 0, now)
		} else {
			aggregate := aggregates[user.Id]
			anchor := trustActivityAnchor(user.CreatedAt, user.LastAPIActivityAt, aggregate.LastPaidCompleteAt)
			info = EvaluateTrustLevel(user.Role, user.TrustLevelOverride, aggregate.PaidAmount, anchor, now)
		}
		user.TrustLevelInfo = &info
	}
	return nil
}

func SetUserTrustLevelOverride(userID int, level *int) error {
	if userID <= 0 {
		return gorm.ErrInvalidData
	}
	if level != nil && (*level < TrustLevelMinUser || *level > TrustLevelMaxUser) {
		return gorm.ErrInvalidData
	}
	if err := DB.Model(&User{}).Where("id = ? AND role < ?", userID, common.RoleAdminUser).
		Update("trust_level_override", level).Error; err != nil {
		return err
	}
	return invalidateUserCache(userID)
}
