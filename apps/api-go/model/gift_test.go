package model

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func setupGiftTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	previousDB, previousLogDB := DB, LOG_DB
	previousRedisEnabled := common.RedisEnabled
	previousMainDatabaseType, previousLogDatabaseType := common.MainDatabaseType(), common.LogDatabaseType()
	common.RedisEnabled = false
	common.SetDatabaseTypes(common.DatabaseTypeSQLite, common.DatabaseTypeSQLite)

	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	DB, LOG_DB = db, db
	require.NoError(t, db.AutoMigrate(&User{}, &Gift{}, &GiftClaim{}))

	t.Cleanup(func() {
		DB, LOG_DB = previousDB, previousLogDB
		common.RedisEnabled = previousRedisEnabled
		common.SetDatabaseTypes(previousMainDatabaseType, previousLogDatabaseType)
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})
	return db
}

func createGiftTestUser(t *testing.T, username string, createdAt int64, usedQuota int) *User {
	t.Helper()
	user := &User{
		Username:  username,
		Password:  "password123",
		CreatedAt: createdAt,
		UsedQuota: usedQuota,
	}
	require.NoError(t, DB.Create(user).Error)
	return user
}

func createTestGift(t *testing.T, quota int, startAt int64, endAt int64, minUsed int, minAgeDays int) *Gift {
	t.Helper()
	gift := &Gift{
		Title:             "compensation",
		Quota:             quota,
		StartAt:           startAt,
		EndAt:             endAt,
		MinUsedQuota:      minUsed,
		MinAccountAgeDays: minAgeDays,
		Enabled:           true,
	}
	require.NoError(t, CreateGift(gift))
	return gift
}

func TestClaimGiftSuccess(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	user := createGiftTestUser(t, "gift_user_ok", now-10*86400, 500)
	gift := createTestGift(t, 1000, now-3600, now+86400, 100, 7)

	claim, err := ClaimGift(user.Id, gift.Id)
	require.NoError(t, err)
	require.Equal(t, 1000, claim.Quota)

	updated, err := GetUserById(user.Id, true)
	require.NoError(t, err)
	require.Equal(t, 1000, updated.Quota)
}

func TestClaimGiftDuplicateRejected(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	user := createGiftTestUser(t, "gift_user_dup", 0, 0)
	gift := createTestGift(t, 100, now-3600, now+86400, 0, 0)

	_, err := ClaimGift(user.Id, gift.Id)
	require.NoError(t, err)
	_, err = ClaimGift(user.Id, gift.Id)
	require.ErrorIs(t, err, ErrGiftAlreadyClaimed)

	updated, err := GetUserById(user.Id, true)
	require.NoError(t, err)
	require.Equal(t, 100, updated.Quota, "quota should only be credited once")
}

func TestClaimGiftWindowEnforced(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	user := createGiftTestUser(t, "gift_user_window", 0, 0)

	notStarted := createTestGift(t, 100, now+3600, now+86400, 0, 0)
	_, err := ClaimGift(user.Id, notStarted.Id)
	require.ErrorIs(t, err, ErrGiftNotStarted)

	expired := createTestGift(t, 100, now-86400, now-3600, 0, 0)
	_, err = ClaimGift(user.Id, expired.Id)
	require.ErrorIs(t, err, ErrGiftExpired)
}

func TestClaimGiftEligibilityGates(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	// 新注册 + 低消耗，不满足门槛
	user := createGiftTestUser(t, "gift_user_gate", now-86400, 10)
	gift := createTestGift(t, 100, now-3600, now+86400, 100, 7)

	_, err := ClaimGift(user.Id, gift.Id)
	require.ErrorIs(t, err, ErrGiftNotEligible)
}

func TestClaimGiftDisabledRejected(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	user := createGiftTestUser(t, "gift_user_disabled", 0, 0)
	gift := createTestGift(t, 100, now-3600, now+86400, 0, 0)
	gift.Enabled = false
	require.NoError(t, UpdateGift(gift))

	_, err := ClaimGift(user.Id, gift.Id)
	require.ErrorIs(t, err, ErrGiftNotFound)
}

func TestGetAvailableGiftsForUser(t *testing.T) {
	setupGiftTestDB(t)
	now := time.Now().Unix()
	user := createGiftTestUser(t, "gift_user_list", 0, 0)
	active := createTestGift(t, 100, now-3600, now+86400, 0, 0)
	createTestGift(t, 100, now-86400*10, now-86400*9, 0, 0) // 过期太久，不展示

	_, err := ClaimGift(user.Id, active.Id)
	require.NoError(t, err)

	gifts, err := GetAvailableGiftsForUser(user.Id)
	require.NoError(t, err)
	require.Len(t, gifts, 1)
	require.True(t, gifts[0].Claimed)
	require.True(t, gifts[0].Eligible)
}
