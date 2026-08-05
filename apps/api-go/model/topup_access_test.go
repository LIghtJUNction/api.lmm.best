package model

import (
	"fmt"
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func setupTopUpAccessTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	previousDB := DB
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	DB = db
	require.NoError(t, db.AutoMigrate(&TopUp{}))

	t.Cleanup(func() {
		DB = previousDB
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})
	return db
}

func TestHasSuccessfulPaidTopUpRequiresCompletedExternalPayment(t *testing.T) {
	db := setupTopUpAccessTestDB(t)
	userID := 42

	fixtures := []TopUp{
		{UserId: userID, TradeNo: "pending", Money: 10, Status: common.TopUpStatusPending, PaymentProvider: PaymentProviderStripe},
		{UserId: userID, TradeNo: "failed", Money: 10, Status: common.TopUpStatusFailed, PaymentProvider: PaymentProviderStripe},
		{UserId: userID, TradeNo: "free", Money: 0, Status: common.TopUpStatusSuccess, PaymentProvider: PaymentProviderStripe},
		{UserId: userID, TradeNo: "balance", Money: 10, Status: common.TopUpStatusSuccess, PaymentMethod: PaymentMethodBalance, PaymentProvider: PaymentProviderBalance},
		{UserId: userID + 1, TradeNo: "other-user", Money: 10, Status: common.TopUpStatusSuccess, PaymentProvider: PaymentProviderStripe},
	}
	require.NoError(t, db.Create(&fixtures).Error)

	granted, err := HasSuccessfulPaidTopUp(userID)
	require.NoError(t, err)
	assert.False(t, granted)

	require.NoError(t, db.Create(&TopUp{
		UserId:        userID,
		TradeNo:       "legacy-success",
		Money:         10,
		Status:        common.TopUpStatusSuccess,
		PaymentMethod: "alipay",
	}).Error)

	granted, err = HasSuccessfulPaidTopUp(userID)
	require.NoError(t, err)
	assert.True(t, granted)
}
