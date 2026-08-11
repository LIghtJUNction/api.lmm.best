package model

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAssistantWeekStartUTC(t *testing.T) {
	assert.Equal(t,
		time.Date(2026, time.August, 10, 0, 0, 0, 0, time.UTC).Unix(),
		AssistantWeekStartUTC(time.Date(2026, time.August, 16, 23, 59, 59, 0, time.FixedZone("UTC+8", 8*60*60))),
	)
}

func TestAssistantWeeklyCreditReserveAndRefund(t *testing.T) {
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&AssistantWeeklyUsage{}))
	weekStart := AssistantWeekStartUTC(time.Date(2026, time.August, 11, 12, 0, 0, 0, time.UTC))

	reserved, err := ReserveAssistantWeeklyCredit(7, weekStart, 100, 60)
	require.NoError(t, err)
	assert.Equal(t, 60, reserved)

	reserved, err = ReserveAssistantWeeklyCredit(7, weekStart, 100, 80)
	require.NoError(t, err)
	assert.Equal(t, 40, reserved)

	used, err := GetAssistantWeeklyUsage(7, weekStart)
	require.NoError(t, err)
	assert.EqualValues(t, 100, used)

	require.NoError(t, RefundAssistantWeeklyCredit(7, weekStart, 35))
	used, err = GetAssistantWeeklyUsage(7, weekStart)
	require.NoError(t, err)
	assert.EqualValues(t, 65, used)
	assert.ErrorIs(t, RefundAssistantWeeklyCredit(7, weekStart, 66), ErrAssistantWeeklyCreditRefundExceedsUsage)
}

func TestAssistantWeeklyCreditIsolatedByWeekAndUser(t *testing.T) {
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&AssistantWeeklyUsage{}))
	weekOne := AssistantWeekStartUTC(time.Date(2026, time.August, 11, 0, 0, 0, 0, time.UTC))
	weekTwo := weekOne + int64(7*24*time.Hour/time.Second)

	for _, item := range []struct {
		userId    int
		weekStart int64
	}{
		{userId: 1, weekStart: weekOne},
		{userId: 2, weekStart: weekOne},
		{userId: 1, weekStart: weekTwo},
	} {
		reserved, err := ReserveAssistantWeeklyCredit(item.userId, item.weekStart, 50, 20)
		require.NoError(t, err)
		assert.Equal(t, 20, reserved)
	}
}
