package model

import (
	"errors"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDeveloperAccessRequestApprovalUnlocksL1WithoutPayment(t *testing.T) {
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&DeveloperAccessRequest{}))

	user := User{
		Username: "unlock-request-user",
		Password: "password",
		Role:     common.RoleCommonUser,
		Status:   common.UserStatusEnabled,
	}
	require.NoError(t, db.Create(&user).Error)

	request, err := SubmitDeveloperAccessRequest(user.Id, "I need access for a verified integration")
	require.NoError(t, err)
	assert.Equal(t, DeveloperAccessRequestPending, request.Status)

	// Repeated submissions are idempotent while the first request is pending.
	repeated, err := SubmitDeveloperAccessRequest(user.Id, "a second browser tab")
	require.NoError(t, err)
	assert.Equal(t, request.Id, repeated.Id)
	assert.Equal(t, request.Reason, repeated.Reason)

	pending, err := ListDeveloperAccessRequests(DeveloperAccessRequestPending, 10)
	require.NoError(t, err)
	require.Len(t, pending, 1)
	assert.Equal(t, user.Username, pending[0].Username)

	approved, err := ReviewDeveloperAccessRequest(99, request.Id, true, "approved for L1")
	require.NoError(t, err)
	assert.Equal(t, DeveloperAccessRequestApproved, approved.Status)
	assert.Equal(t, 99, approved.AdminUserId)
	assert.Positive(t, approved.ReviewedAt)

	var activated User
	require.NoError(t, db.First(&activated, user.Id).Error)
	assert.Positive(t, activated.ConsoleActivatedAt)
	access, err := GetDeveloperAccessStateForUserBase(activated.ToBaseUser())
	require.NoError(t, err)
	assert.True(t, access.Granted)
	assert.False(t, access.PaidActivationComplete)

	_, err = ReviewDeveloperAccessRequest(99, request.Id, true, "duplicate")
	assert.ErrorIs(t, err, ErrDeveloperAccessRequestReviewed)
}

func TestDeveloperAccessRequestRejectionDoesNotActivate(t *testing.T) {
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&DeveloperAccessRequest{}))

	user := User{Username: "rejected-request-user", Password: "password", Role: common.RoleCommonUser}
	require.NoError(t, db.Create(&user).Error)
	request, err := SubmitDeveloperAccessRequest(user.Id, "please review")
	require.NoError(t, err)

	rejected, err := ReviewDeveloperAccessRequest(99, request.Id, false, "please provide more detail")
	require.NoError(t, err)
	assert.Equal(t, DeveloperAccessRequestRejected, rejected.Status)

	var unchanged User
	require.NoError(t, db.First(&unchanged, user.Id).Error)
	assert.Zero(t, unchanged.ConsoleActivatedAt)
	latest, err := GetDeveloperAccessRequest(user.Id)
	require.NoError(t, err)
	require.NotNil(t, latest)
	assert.Equal(t, "please provide more detail", latest.AdminNote)
}

func TestDeveloperAccessRequestTextLimit(t *testing.T) {
	db := setupConsoleActivationTestDB(t)
	require.NoError(t, db.AutoMigrate(&DeveloperAccessRequest{}))
	user := User{Username: "long-request-user", Password: "password", Role: common.RoleCommonUser}
	require.NoError(t, db.Create(&user).Error)

	_, err := SubmitDeveloperAccessRequest(user.Id, string(make([]rune, maxDeveloperAccessRequestNote+1)))
	assert.ErrorIs(t, err, ErrDeveloperAccessRequestNoteTooLong)
	assert.False(t, errors.Is(err, ErrDeveloperAccessRequestReviewed))
}
