package service

import (
	"crypto/sha256"
	"encoding/base64"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/LIghtJUNction/api.lmm.best/setting/system_setting"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func resetOAuthServiceState(t *testing.T) {
	t.Helper()
	require.NoError(t, model.DB.AutoMigrate(
		&model.AuthFlow{}, &model.OAuthDeviceGrant{}, &model.OAuthGrantToken{}, &model.User{},
	))
	require.NoError(t, model.DB.Exec("DELETE FROM auth_flows").Error)
	require.NoError(t, model.DB.Exec("DELETE FROM oauth_device_grants").Error)
	require.NoError(t, model.DB.Exec("DELETE FROM oauth_grant_tokens").Error)
	originalAddress := system_setting.ServerAddress
	originalSecret := common.SessionSecret
	system_setting.ServerAddress = "https://api.example.test"
	common.SessionSecret = "oauth-authority-test-session-secret"
	t.Cleanup(func() {
		system_setting.ServerAddress = originalAddress
		common.SessionSecret = originalSecret
	})
}

func oauthPKCE(t *testing.T) (string, string) {
	t.Helper()
	verifier := strings.Repeat("A", 64)
	digest := sha256.Sum256([]byte(verifier))
	return verifier, base64.RawURLEncoding.EncodeToString(digest[:])
}

// pi-lens-ignore: go-test-functions
func TestOAuthAuthorizationCodePKCEIsBoundAndSingleUse(t *testing.T) {
	resetOAuthServiceState(t)
	now := time.Now().UTC().Truncate(time.Second)
	verifier, challenge := oauthPKCE(t)
	state := strings.Repeat("s", 43)
	redirectURI := "http://127.0.0.1:49152/oauth/callback"

	requestToken, consentURL, err := CreateOAuthAuthorizationRequest(OAuthAuthorizationInput{
		ClientId: OAuthBootstrapClientId, RedirectURI: redirectURI, ResponseType: "code",
		Scope: OAuthScopeApiKeysReveal + " " + OAuthScopeApiKeysList,
		State: state, CodeChallenge: challenge, CodeChallengeMethod: "S256",
	}, now)
	require.NoError(t, err)
	assert.Contains(t, consentURL, "/oauth/consent?request=")
	preview, err := GetOAuthAuthorizationPreview(requestToken)
	require.NoError(t, err)
	assert.Equal(t, []string{OAuthScopeApiKeysList, OAuthScopeApiKeysReveal}, preview.Scopes)

	decision, err := DecideOAuthAuthorization(requestToken, 77, true, now.Add(time.Second))
	require.NoError(t, err)
	callback, err := url.Parse(decision.RedirectURI)
	require.NoError(t, err)
	assert.Equal(t, state, callback.Query().Get("state"))
	code := callback.Query().Get("code")
	require.NotEmpty(t, code)

	response, err := ExchangeOAuthAuthorizationCode(
		code, OAuthBootstrapClientId, redirectURI, verifier, now.Add(2*time.Second),
	)
	require.NoError(t, err)
	assert.Equal(t, "Bearer", response.TokenType)
	assert.NotEmpty(t, response.AccessToken)
	assert.NotEmpty(t, response.RefreshToken)
	access, err := ValidateOAuthAccessToken(response.AccessToken, OAuthScopeApiKeysList)
	require.NoError(t, err)
	assert.Equal(t, 77, access.UserId)

	replayed, err := ExchangeOAuthAuthorizationCode(
		code, OAuthBootstrapClientId, redirectURI, verifier, now.Add(3*time.Second),
	)
	assert.Nil(t, replayed)
	assert.Error(t, err)
}

// pi-lens-ignore: go-test-functions
func TestOAuthDeviceGrantAndRefreshPreserveScopes(t *testing.T) {
	resetOAuthServiceState(t)
	now := time.Now().UTC().Truncate(time.Second)
	scope := OAuthScopeApiKeysCreate + " " + OAuthScopeApiKeysList
	device, err := CreateOAuthDeviceAuthorization(OAuthBootstrapClientId, scope, now)
	require.NoError(t, err)
	assert.Contains(t, device.VerificationURIComplete, "user_code=")

	pending, err := ExchangeOAuthDeviceCode(device.DeviceCode, OAuthBootstrapClientId, now)
	assert.Nil(t, pending)
	assert.ErrorIs(t, err, model.ErrOAuthAuthorizationPending)
	require.NoError(t, DecideOAuthDeviceAuthorization(device.UserCode, 88, true, now.Add(time.Second)))

	issued, err := ExchangeOAuthDeviceCode(
		device.DeviceCode, OAuthBootstrapClientId, now.Add(time.Duration(device.Interval)*time.Second),
	)
	require.NoError(t, err)
	assert.Equal(t, OAuthScopeApiKeysCreate+" "+OAuthScopeApiKeysList, issued.Scope)

	refreshed, err := ExchangeOAuthRefreshToken(
		issued.RefreshToken, OAuthBootstrapClientId, now.Add(time.Minute),
	)
	require.NoError(t, err)
	assert.Equal(t, issued.Scope, refreshed.Scope)
	assert.NotEqual(t, issued.RefreshToken, refreshed.RefreshToken)
}

// pi-lens-ignore: go-test-functions
func TestOAuthBootstrapAPIKeyCreateListAndReveal(t *testing.T) {
	resetOAuthServiceState(t)
	require.NoError(t, model.DB.Exec("DELETE FROM tokens").Error)
	require.NoError(t, model.DB.Exec("DELETE FROM users").Error)
	user := model.User{Username: "oauth-key-owner", Status: common.UserStatusEnabled, Role: common.RoleCommonUser}
	require.NoError(t, model.DB.Create(&user).Error)

	created, err := CreateOAuthBootstrapAPIKey(user.Id, "CLI key", time.Now().UTC())
	require.NoError(t, err)
	assert.NotEmpty(t, created.Key)
	assert.Equal(t, "CLI key", created.Name)

	keys, err := ListOAuthBootstrapAPIKeys(user.Id)
	require.NoError(t, err)
	require.Len(t, keys, 1)
	assert.Equal(t, created.Id, keys[0].Id)

	revealed, err := RevealOAuthBootstrapAPIKey(user.Id, created.Id)
	require.NoError(t, err)
	assert.Equal(t, created.Key, revealed.Key)
	foreign, err := RevealOAuthBootstrapAPIKey(user.Id+1, created.Id)
	assert.Nil(t, foreign)
	assert.ErrorIs(t, err, ErrOAuthAPIKeyNotFound)
}

// pi-lens-ignore: go-test-functions
func TestOAuthLoopbackRedirectValidationIsExact(t *testing.T) {
	assert.True(t, validOAuthRedirectURI("http://127.0.0.1:49152/oauth/callback"))
	assert.True(t, validOAuthRedirectURI("http://[::1]:49152/oauth/callback"))
	assert.False(t, validOAuthRedirectURI("http://localhost:49152/oauth/callback"))
	assert.False(t, validOAuthRedirectURI("http://127.0.0.1:80/oauth/callback"))
	assert.False(t, validOAuthRedirectURI("http://127.0.0.1:49152/other"))
	assert.False(t, validOAuthRedirectURI("http://127.0.0.1:49152/oauth/callback?next=evil"))
	assert.False(t, validOAuthRedirectURI("https://127.0.0.1:49152/oauth/callback"))
}

// pi-lens-ignore: go-test-functions
func TestOAuthAuthorizationRejectsUnknownScopeAndWeakState(t *testing.T) {
	resetOAuthServiceState(t)
	verifier, challenge := oauthPKCE(t)
	assert.NotEmpty(t, verifier)
	base := OAuthAuthorizationInput{
		ClientId:     OAuthBootstrapClientId,
		RedirectURI:  "http://127.0.0.1:49152/oauth/callback",
		ResponseType: "code", Scope: OAuthScopeApiKeysList,
		State: strings.Repeat("s", 43), CodeChallenge: challenge, CodeChallengeMethod: "S256",
	}
	unknownScope := base
	unknownScope.Scope = "admin:*"
	requestToken, consentURL, err := CreateOAuthAuthorizationRequest(unknownScope, time.Now())
	assert.Empty(t, requestToken)
	assert.Empty(t, consentURL)
	assert.ErrorIs(t, err, ErrOAuthInvalidScope)

	weakState := base
	weakState.State = "short"
	requestToken, consentURL, err = CreateOAuthAuthorizationRequest(weakState, time.Now())
	assert.Empty(t, requestToken)
	assert.Empty(t, consentURL)
	assert.ErrorIs(t, err, ErrOAuthInvalidRequest)
}
