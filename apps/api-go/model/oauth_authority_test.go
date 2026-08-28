package model

import (
	"errors"
	"testing"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOAuthHashVectorsMatchTheRustAuthorityContract(t *testing.T) {
	previous := common.SessionSecret
	common.SessionSecret = "oauth-contract-test-session-secret"
	t.Cleanup(func() { common.SessionSecret = previous })

	assert.Equal(t,
		"bdce4c4b125c53d8d191a6c988bb84fd3ac703fa913fa5797250f8d516271562",
		authFlowTokenHash("authorization-request-token"),
	)
	assert.Equal(t,
		"bf9ec23b8a5d2ccd7e18e2ac97b59445be4592f85c0479e40f3c68e130aa05be",
		oauthOpaqueHash(OAuthTokenKindAccess, "lmm_oat_access-token-value"),
	)
	assert.Equal(t,
		"0412268c4e323ca09d48a2f8a0740f4377a89e798a24dec063050984629070b2",
		oauthOpaqueHash(OAuthTokenKindRefresh, "lmm_ort_refresh-token-value"),
	)
}

func resetOAuthTables(t *testing.T) {
	t.Helper()
	truncateTables(t)
	require.NoError(t, DB.AutoMigrate(&OAuthDeviceGrant{}, &OAuthGrantToken{}))
	require.NoError(t, DB.Exec("DELETE FROM oauth_device_grants").Error)
	require.NoError(t, DB.Exec("DELETE FROM oauth_grant_tokens").Error)
}

func TestOAuthDeviceGrantIsHashedRateLimitedAndConsumedOnce(t *testing.T) {
	resetOAuthTables(t)
	now := time.Now().UTC().Truncate(time.Second)
	deviceCode, userCode, created, err := CreateOAuthDeviceGrant(
		"lmm-api-rs", "api_keys:list api_keys:create api_keys:reveal",
		now.Add(10*time.Minute), 5,
	)
	require.NoError(t, err)
	require.NotEmpty(t, deviceCode)
	require.NotEmpty(t, userCode)
	assert.NotContains(t, created.DeviceCodeHash, deviceCode)
	assert.NotContains(t, created.UserCodeHash, normalizeOAuthUserCode(userCode))

	pendingGrant, err := ConsumeOAuthDeviceGrant(deviceCode, "lmm-api-rs", now)
	assert.Nil(t, pendingGrant)
	assert.ErrorIs(t, err, ErrOAuthAuthorizationPending)

	slowedGrant, err := ConsumeOAuthDeviceGrant(deviceCode, "lmm-api-rs", now.Add(time.Second))
	assert.Nil(t, slowedGrant)
	assert.ErrorIs(t, err, ErrOAuthSlowDown)
	var slowed OAuthDeviceGrant
	require.NoError(t, DB.First(&slowed, created.Id).Error)
	assert.Equal(t, 10, slowed.IntervalSeconds)
	require.NotNil(t, slowed.LastPolledAt)

	approved, err := ApproveOAuthDeviceGrant(userCode, 42, true, now.Add(2*time.Second))
	require.NoError(t, err)
	assert.Equal(t, OAuthDeviceStatusApproved, approved.Status)

	consumed, err := ConsumeOAuthDeviceGrant(deviceCode, "lmm-api-rs", now.Add(12*time.Second))
	require.NoError(t, err)
	assert.Equal(t, 42, consumed.UserId)
	require.NotNil(t, consumed.ConsumedAt)

	reusedGrant, err := ConsumeOAuthDeviceGrant(deviceCode, "lmm-api-rs", now.Add(30*time.Second))
	assert.Nil(t, reusedGrant)
	assert.ErrorIs(t, err, ErrOAuthInvalidGrant)
}

func TestOAuthRefreshReplayRevokesTheWholeFamily(t *testing.T) {
	resetOAuthTables(t)
	now := time.Now().UTC().Truncate(time.Second)
	initial, err := CreateOAuthTokenPair(
		DB, "lmm-api-rs", 7, "api_keys:list", 15*time.Minute, 30*24*time.Hour, now,
	)
	require.NoError(t, err)

	rotated, err := RotateOAuthRefreshToken(
		initial.RefreshToken, "lmm-api-rs", 15*time.Minute, 30*24*time.Hour, now.Add(time.Minute),
	)
	require.NoError(t, err)
	require.Equal(t, initial.FamilyId, rotated.FamilyId)
	validated, err := ValidateOAuthAccessToken(rotated.AccessToken, now.Add(2*time.Minute))
	require.NoError(t, err)
	require.NotNil(t, validated)

	replayedPair, err := RotateOAuthRefreshToken(
		initial.RefreshToken, "lmm-api-rs", 15*time.Minute, 30*24*time.Hour, now.Add(2*time.Minute),
	)
	assert.Nil(t, replayedPair)
	assert.ErrorIs(t, err, ErrOAuthRefreshReplay)
	revokedAccess, err := ValidateOAuthAccessToken(rotated.AccessToken, now.Add(3*time.Minute))
	assert.Nil(t, revokedAccess)
	assert.ErrorIs(t, err, ErrOAuthExpiredToken)

	var active int64
	require.NoError(t, DB.Model(&OAuthGrantToken{}).
		Where("family_id = ? AND revoked_at IS NULL", initial.FamilyId).
		Count(&active).Error)
	assert.Zero(t, active)
}

func TestOAuthTokenRevocationIsIdempotent(t *testing.T) {
	resetOAuthTables(t)
	now := time.Now().UTC().Truncate(time.Second)
	pair, err := CreateOAuthTokenPair(
		DB, "lmm-api-rs", 9, "api_keys:list", 15*time.Minute, time.Hour, now,
	)
	require.NoError(t, err)

	require.NoError(t, RevokeOAuthToken(pair.AccessToken, now.Add(time.Second)))
	require.NoError(t, RevokeOAuthToken(pair.AccessToken, now.Add(2*time.Second)))
	revoked, err := ValidateOAuthAccessToken(pair.AccessToken, now.Add(3*time.Second))
	assert.Nil(t, revoked)
	assert.True(t, errors.Is(err, ErrOAuthExpiredToken))
}

func TestOAuthRawSecretsAreNeverPersisted(t *testing.T) {
	resetOAuthTables(t)
	now := time.Now().UTC().Truncate(time.Second)
	pair, err := CreateOAuthTokenPair(
		DB, "lmm-api-rs", 11, "api_keys:list", time.Minute, time.Hour, now,
	)
	require.NoError(t, err)

	var records []OAuthGrantToken
	require.NoError(t, DB.Where("family_id = ?", pair.FamilyId).Find(&records).Error)
	require.Len(t, records, 2)
	for _, record := range records {
		assert.NotEqual(t, pair.AccessToken, record.TokenHash)
		assert.NotEqual(t, pair.RefreshToken, record.TokenHash)
		assert.Len(t, record.TokenHash, 64)
	}
}
