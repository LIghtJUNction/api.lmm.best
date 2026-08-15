package model

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestIsLinuxDOEmailRequiresExactDomain(t *testing.T) {
	for _, test := range []struct {
		email string
		want  bool
	}{
		{email: "member@linux.do", want: true},
		{email: " Member@LINUX.DO ", want: true},
		{email: "member@mail.linux.do"},
		{email: "member@linux.do.example"},
		{email: "linux.do"},
	} {
		assert.Equal(t, test.want, IsLinuxDOEmail(test.email), test.email)
	}
}

func TestEffectivePaymentRestrictionFlagsIncludesLegacyLinuxDOEmail(t *testing.T) {
	user := &User{
		Email:                   "member@linux.do",
		PaymentRestrictionFlags: PaymentRestrictionLinuxDOHighScore,
	}
	assert.Equal(
		t,
		PaymentRestrictionLinuxDOEmail|PaymentRestrictionLinuxDOHighScore,
		EffectivePaymentRestrictionFlags(user),
	)
	assert.True(t, IsPaymentRestricted(user))
}

func TestAddPaymentRestrictionFlagsPreservesExistingReasons(t *testing.T) {
	truncateTables(t)
	user := &User{
		Username:                "payment-restricted-user",
		Password:                "password123",
		PaymentRestrictionFlags: PaymentRestrictionLinuxDOEmail,
	}
	require.NoError(t, DB.Create(user).Error)

	require.NoError(t, AddPaymentRestrictionFlags(user.Id, PaymentRestrictionLinuxDOHighScore))
	require.NoError(t, DB.First(user, user.Id).Error)
	assert.Equal(
		t,
		PaymentRestrictionLinuxDOEmail|PaymentRestrictionLinuxDOHighScore,
		user.PaymentRestrictionFlags,
	)
}

func TestPaymentRestrictionMarkerRequiresAdminPopulation(t *testing.T) {
	user := &User{PaymentRestrictionFlags: PaymentRestrictionLinuxDOHighScore}
	selfPayload, err := json.Marshal(user)
	require.NoError(t, err)
	assert.NotContains(t, string(selfPayload), "payment_restriction")

	PopulateAdminPaymentRestriction(user)
	adminPayload, err := json.Marshal(user)
	require.NoError(t, err)
	assert.Contains(t, string(adminPayload), `"payment_restriction_flags":2`)
}

func TestDisposableEmailMarkerIsAdminOnly(t *testing.T) {
	user := &User{Email: "person@mailinator.com"}
	selfPayload, err := json.Marshal(user)
	require.NoError(t, err)
	assert.NotContains(t, string(selfPayload), "disposable_email")

	PopulateAdminPaymentRestriction(user)
	adminPayload, err := json.Marshal(user)
	require.NoError(t, err)
	assert.Contains(t, string(adminPayload), `"disposable_email":true`)
}
