package service

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func setupAssistantFundingTestDB(t *testing.T, quota int) (*gorm.DB, int, int64) {
	t.Helper()
	previousDB := model.DB
	previousRedisEnabled := common.RedisEnabled
	previousBatchUpdateEnabled := common.BatchUpdateEnabled
	common.RedisEnabled = false
	common.BatchUpdateEnabled = false
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	model.DB = db
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.AssistantWeeklyUsage{}))
	user := model.User{Username: "assistant-user", Password: "password", Quota: quota}
	require.NoError(t, db.Create(&user).Error)
	weekStart := model.AssistantWeekStartUTC(time.Date(2026, time.August, 11, 0, 0, 0, 0, time.UTC))
	t.Cleanup(func() {
		model.DB = previousDB
		common.RedisEnabled = previousRedisEnabled
		common.BatchUpdateEnabled = previousBatchUpdateEnabled
		sqlDB, dbErr := db.DB()
		if dbErr == nil {
			_ = sqlDB.Close()
		}
	})
	return db, user.Id, weekStart
}

func TestAssistantFundingUsesCreditBeforeWallet(t *testing.T) {
	_, userId, weekStart := setupAssistantFundingTestDB(t, 100)
	funding := NewAssistantFunding(userId, weekStart, 80)

	require.NoError(t, funding.PreConsume(120))
	assert.Equal(t, 80, funding.creditConsumed)
	assert.Equal(t, 40, funding.walletConsumed)
	quota, err := model.GetUserQuota(userId, true)
	require.NoError(t, err)
	assert.Equal(t, 60, quota)

	require.NoError(t, funding.Settle(-50))
	assert.Equal(t, 70, funding.creditConsumed)
	assert.Zero(t, funding.walletConsumed)
	quota, err = model.GetUserQuota(userId, true)
	require.NoError(t, err)
	assert.Equal(t, 100, quota)
}

func TestAssistantFundingFallsBackToWalletAfterCredit(t *testing.T) {
	_, userId, weekStart := setupAssistantFundingTestDB(t, 100)
	funding := NewAssistantFunding(userId, weekStart, 50)

	require.NoError(t, funding.PreConsume(30))
	require.NoError(t, funding.Settle(40))
	assert.Equal(t, 50, funding.creditConsumed)
	assert.Equal(t, 20, funding.walletConsumed)
	quota, err := model.GetUserQuota(userId, true)
	require.NoError(t, err)
	assert.Equal(t, 80, quota)
}

func TestAssistantFundingRejectsAndRollsBackWhenWalletIsInsufficient(t *testing.T) {
	_, userId, weekStart := setupAssistantFundingTestDB(t, 10)
	funding := NewAssistantFunding(userId, weekStart, 50)

	err := funding.PreConsume(80)
	assert.True(t, errors.Is(err, ErrAssistantBalanceInsufficient))
	used, usageErr := model.GetAssistantWeeklyUsage(userId, weekStart)
	require.NoError(t, usageErr)
	assert.Zero(t, used)
	quota, quotaErr := model.GetUserQuota(userId, true)
	require.NoError(t, quotaErr)
	assert.Equal(t, 10, quota)
}

func TestAssistantFundingRefundsBothSources(t *testing.T) {
	_, userId, weekStart := setupAssistantFundingTestDB(t, 100)
	funding := NewAssistantFunding(userId, weekStart, 50)
	require.NoError(t, funding.PreConsume(80))
	require.NoError(t, funding.Refund())

	used, err := model.GetAssistantWeeklyUsage(userId, weekStart)
	require.NoError(t, err)
	assert.Zero(t, used)
	quota, err := model.GetUserQuota(userId, true)
	require.NoError(t, err)
	assert.Equal(t, 100, quota)
}
