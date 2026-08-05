package model

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func intPointer(value int) *int { return &value }

func TestEvaluateTrustLevelRoleMapping(t *testing.T) {
	assert.Equal(t, TrustLevelRoot, EvaluateTrustLevel(common.RoleRootUser, nil, 0, 0, 1).Level)
	assert.Equal(t, TrustLevelAdmin, EvaluateTrustLevel(common.RoleAdminUser, nil, 0, 0, 1).Level)
	assert.Equal(t, TrustLevelMinUser, EvaluateTrustLevel(common.RoleCommonUser, nil, 0, 0, 1).Level)
}

func TestEvaluateTrustLevelPaidThresholdsAndDiscounts(t *testing.T) {
	now := time.Now().Unix()
	for _, test := range []struct {
		paid     float64
		level    int
		discount float64
	}{
		{paid: 9.99, level: 0, discount: 0},
		{paid: 10, level: 1, discount: 0},
		{paid: 100, level: 2, discount: 3},
		{paid: 500, level: 3, discount: 6},
		{paid: 2000, level: 4, discount: 10},
	} {
		info := EvaluateTrustLevel(common.RoleCommonUser, nil, test.paid, now, now)
		assert.Equal(t, test.level, info.Level)
		assert.InDelta(t, test.discount, info.DiscountPercent, 0.0001)
	}
}

func TestEvaluateTrustLevelDecaysEveryNinetyDays(t *testing.T) {
	period := int64(trustLevelDecayPeriod / time.Second)
	now := int64(1_800_000_000)
	info := EvaluateTrustLevel(common.RoleCommonUser, nil, 2000, now-2*period-1, now)

	assert.Equal(t, 4, info.AutomaticLevel)
	assert.Equal(t, 2, info.Level)
	assert.Equal(t, 2, info.InactivityDecaySteps)
	assert.NotNil(t, info.NextDecayAt)
}

func TestEvaluateTrustLevelOverrideDisablesDecay(t *testing.T) {
	now := int64(1_800_000_000)
	info := EvaluateTrustLevel(common.RoleCommonUser, intPointer(3), 10, 1, now)

	assert.Equal(t, 1, info.AutomaticLevel)
	assert.Equal(t, 3, info.Level)
	assert.True(t, info.Overridden)
	assert.Nil(t, info.NextDecayAt)
}

func TestGetTrustLevelInfoUsesCompletedExternalTopUps(t *testing.T) {
	previousDB := DB
	previousRedis := common.RedisEnabled
	common.RedisEnabled = false
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "_"))), &gorm.Config{})
	require.NoError(t, err)
	DB = db
	require.NoError(t, db.AutoMigrate(&User{}, &TopUp{}))
	t.Cleanup(func() {
		DB = previousDB
		common.RedisEnabled = previousRedis
		sqlDB, _ := db.DB()
		_ = sqlDB.Close()
	})

	user := User{Username: "trust-user", Password: "password", Role: common.RoleCommonUser, Status: common.UserStatusEnabled}
	require.NoError(t, db.Create(&user).Error)
	require.NoError(t, db.Create(&TopUp{UserId: user.Id, TradeNo: "pending", Amount: 2000 * int64(common.QuotaPerUnit), Money: 2000, Status: common.TopUpStatusPending, PaymentProvider: PaymentProviderStripe}).Error)
	require.NoError(t, db.Create(&TopUp{UserId: user.Id, TradeNo: "balance", Amount: 2000 * int64(common.QuotaPerUnit), Money: 2000, Status: common.TopUpStatusSuccess, PaymentMethod: PaymentMethodBalance, PaymentProvider: PaymentProviderBalance}).Error)
	require.NoError(t, db.Create(&TopUp{UserId: user.Id, TradeNo: "paid", Amount: 100 * int64(common.QuotaPerUnit), Money: 14.6, Status: common.TopUpStatusSuccess, PaymentProvider: PaymentProviderStripe, CompleteTime: time.Now().Unix()}).Error)

	info, err := GetTrustLevelInfoForUser(&user)
	require.NoError(t, err)
	assert.Equal(t, 2, info.Level)
	assert.Equal(t, 100.0, info.PaidAmount)
}
