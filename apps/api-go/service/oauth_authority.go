package service

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/LIghtJUNction/api.lmm.best/setting/system_setting"
	"gorm.io/gorm"
)

const (
	OAuthBootstrapClientId = "lmm-api-rs"

	OAuthScopeApiKeysList    = "api_keys:list"
	OAuthScopeApiKeysCreate  = "api_keys:create"
	OAuthScopeApiKeysReveal  = "api_keys:reveal"
	OAuthScopeCCSwitchImport = "cc_switch:import"

	oauthAuthorizationRequestPurpose = "oauth_authorize_request"
	oauthAuthorizationCodePurpose    = "oauth_authorization_code"
	oauthAuthorizationRequestTTL     = 5 * time.Minute
	oauthAuthorizationCodeTTL        = 90 * time.Second
	oauthDeviceGrantTTL              = 10 * time.Minute
	oauthAccessTokenTTL              = 15 * time.Minute
	oauthRefreshTokenTTL             = 30 * 24 * time.Hour
	oauthDevicePollInterval          = 5
)

var (
	ErrOAuthInvalidRequest     = errors.New("invalid_request")
	ErrOAuthInvalidClient      = errors.New("invalid_client")
	ErrOAuthInvalidScope       = errors.New("invalid_scope")
	ErrOAuthInvalidRedirectURI = errors.New("invalid_redirect_uri")
	ErrOAuthInvalidPKCE        = errors.New("invalid_pkce")
	ErrOAuthInvalidGrant       = errors.New("invalid_grant")
	ErrOAuthUnsupportedGrant   = errors.New("unsupported_grant_type")
	ErrOAuthAccessDenied       = errors.New("access_denied")
	ErrOAuthUnavailable        = errors.New("temporarily_unavailable")
)

var oauthAllowedScopes = map[string]struct{}{
	OAuthScopeApiKeysList:    {},
	OAuthScopeApiKeysCreate:  {},
	OAuthScopeApiKeysReveal:  {},
	OAuthScopeCCSwitchImport: {},
}

type OAuthAuthorizationServerMetadata struct {
	Issuer                            string   `json:"issuer"`
	AuthorizationEndpoint             string   `json:"authorization_endpoint"`
	TokenEndpoint                     string   `json:"token_endpoint"`
	DeviceAuthorizationEndpoint       string   `json:"device_authorization_endpoint"`
	RevocationEndpoint                string   `json:"revocation_endpoint"`
	ResponseTypesSupported            []string `json:"response_types_supported"`
	GrantTypesSupported               []string `json:"grant_types_supported"`
	CodeChallengeMethodsSupported     []string `json:"code_challenge_methods_supported"`
	TokenEndpointAuthMethodsSupported []string `json:"token_endpoint_auth_methods_supported"`
	ScopesSupported                   []string `json:"scopes_supported"`
}

type OAuthAuthorizationInput struct {
	ClientId            string
	RedirectURI         string
	ResponseType        string
	Scope               string
	State               string
	CodeChallenge       string
	CodeChallengeMethod string
}

type OAuthAuthorizationPreview struct {
	ClientId    string    `json:"client_id"`
	ClientName  string    `json:"client_name"`
	RedirectURI string    `json:"redirect_uri"`
	Scopes      []string  `json:"scopes"`
	ExpiresAt   time.Time `json:"expires_at"`
}

type OAuthAuthorizationDecision struct {
	RedirectURI string `json:"redirect_uri"`
}

type OAuthDeviceAuthorization struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

type OAuthTokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token,omitempty"`
	Scope        string `json:"scope"`
}

type oauthAuthorizationPayload struct {
	ClientId      string `json:"client_id"`
	RedirectURI   string `json:"redirect_uri"`
	Scope         string `json:"scope"`
	State         string `json:"state"`
	CodeChallenge string `json:"code_challenge"`
}

func OAuthMetadata() (*OAuthAuthorizationServerMetadata, error) {
	issuer, err := OAuthIssuer()
	if err != nil {
		return nil, err
	}
	scopes := make([]string, 0, len(oauthAllowedScopes))
	for scope := range oauthAllowedScopes {
		scopes = append(scopes, scope)
	}
	sort.Strings(scopes)
	return &OAuthAuthorizationServerMetadata{
		Issuer:                      issuer,
		AuthorizationEndpoint:       issuer + "/oauth/authorize",
		TokenEndpoint:               issuer + "/oauth/token",
		DeviceAuthorizationEndpoint: issuer + "/oauth/device/code",
		RevocationEndpoint:          issuer + "/oauth/revoke",
		ResponseTypesSupported:      []string{"code"},
		GrantTypesSupported: []string{
			"authorization_code",
			"refresh_token",
			"urn:ietf:params:oauth:grant-type:device_code",
		},
		CodeChallengeMethodsSupported:     []string{"S256"},
		TokenEndpointAuthMethodsSupported: []string{"none"},
		ScopesSupported:                   scopes,
	}, nil
}

func OAuthIssuer() (string, error) {
	raw := strings.TrimSpace(system_setting.ServerAddress)
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", fmt.Errorf("configure a valid OAuth server address: %w", ErrOAuthInvalidRequest)
	}
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && isLoopbackHostname(parsed.Hostname())) {
		return "", fmt.Errorf("oauth issuer requires https: %w", ErrOAuthInvalidRequest)
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawPath = ""
	return strings.TrimRight(parsed.String(), "/"), nil
}

func CreateOAuthAuthorizationRequest(input OAuthAuthorizationInput, now time.Time) (string, string, error) {
	payload, err := validateOAuthAuthorizationInput(input)
	if err != nil {
		return "", "", err
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", "", fmt.Errorf("encode oauth authorization request: %w", err)
	}
	requestToken, requestFlow, err := model.CreateAuthFlow(model.AuthFlowCreate{
		Purpose:   oauthAuthorizationRequestPurpose,
		Provider:  OAuthBootstrapClientId,
		Payload:   string(encoded),
		ExpiresAt: now.Add(oauthAuthorizationRequestTTL),
	})
	if err != nil {
		return "", "", fmt.Errorf("create oauth authorization request: %w", err)
	}
	if requestFlow == nil {
		return "", "", errors.New("create oauth authorization request: missing flow")
	}
	issuer, err := OAuthIssuer()
	if err != nil {
		return "", "", err
	}
	consentURL := issuer + "/oauth/consent?request=" + url.QueryEscape(requestToken)
	return requestToken, consentURL, nil
}

func GetOAuthAuthorizationPreview(requestToken string) (*OAuthAuthorizationPreview, error) {
	flow, err := model.GetAuthFlow(requestToken, model.AuthFlowMatch{
		Purpose:  oauthAuthorizationRequestPurpose,
		Provider: OAuthBootstrapClientId,
	})
	if err != nil {
		return nil, fmt.Errorf("get oauth authorization request: %w", ErrOAuthInvalidGrant)
	}
	payload, err := decodeOAuthAuthorizationPayload(flow.Payload)
	if err != nil {
		return nil, err
	}
	return &OAuthAuthorizationPreview{
		ClientId:    payload.ClientId,
		ClientName:  "lmm-api-rs",
		RedirectURI: payload.RedirectURI,
		Scopes:      strings.Fields(payload.Scope),
		ExpiresAt:   flow.ExpiresAt,
	}, nil
}

func DecideOAuthAuthorization(requestToken string, userId int, approve bool, now time.Time) (*OAuthAuthorizationDecision, error) {
	if userId <= 0 {
		return nil, ErrOAuthAccessDenied
	}
	var decision *OAuthAuthorizationDecision
	consumedRequest, err := model.ConsumeAuthFlowWithAction(requestToken, model.AuthFlowMatch{
		Purpose:  oauthAuthorizationRequestPurpose,
		Provider: OAuthBootstrapClientId,
	}, func(tx *gorm.DB, flow *model.AuthFlow) error {
		payload, err := decodeOAuthAuthorizationPayload(flow.Payload)
		if err != nil {
			return err
		}
		callback, err := url.Parse(payload.RedirectURI)
		if err != nil {
			return ErrOAuthInvalidRedirectURI
		}
		query := callback.Query()
		query.Set("state", payload.State)
		if !approve {
			query.Set("error", "access_denied")
			query.Set("error_description", "The user denied the authorization request.")
			callback.RawQuery = query.Encode()
			decision = &OAuthAuthorizationDecision{RedirectURI: callback.String()}
			return nil
		}
		codePayload, err := json.Marshal(payload)
		if err != nil {
			return fmt.Errorf("encode oauth authorization code: %w", err)
		}
		code, codeFlow, err := model.CreateAuthFlowWithTx(tx, model.AuthFlowCreate{
			Purpose:   oauthAuthorizationCodePurpose,
			Provider:  OAuthBootstrapClientId,
			UserId:    userId,
			Payload:   string(codePayload),
			ExpiresAt: now.Add(oauthAuthorizationCodeTTL),
		})
		if err != nil {
			return fmt.Errorf("create oauth authorization code: %w", err)
		}
		if codeFlow == nil {
			return errors.New("create oauth authorization code: missing flow")
		}
		query.Set("code", code)
		callback.RawQuery = query.Encode()
		decision = &OAuthAuthorizationDecision{RedirectURI: callback.String()}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("decide oauth authorization request: %w", err)
	}
	if consumedRequest == nil || decision == nil {
		return nil, errors.New("decide oauth authorization request: missing result")
	}
	return decision, nil
}

func ExchangeOAuthAuthorizationCode(code, clientId, redirectURI, verifier string, now time.Time) (*OAuthTokenResponse, error) {
	if clientId != OAuthBootstrapClientId || !validOAuthRedirectURI(redirectURI) || !validPKCEVerifier(verifier) {
		return nil, ErrOAuthInvalidGrant
	}
	var pair *model.OAuthTokenPair
	var scope string
	consumedCode, err := model.ConsumeAuthFlowWithAction(code, model.AuthFlowMatch{
		Purpose:  oauthAuthorizationCodePurpose,
		Provider: OAuthBootstrapClientId,
	}, func(tx *gorm.DB, flow *model.AuthFlow) error {
		payload, err := decodeOAuthAuthorizationPayload(flow.Payload)
		if err != nil {
			return err
		}
		if payload.ClientId != clientId || payload.RedirectURI != redirectURI || !verifyPKCE(payload.CodeChallenge, verifier) {
			return ErrOAuthInvalidGrant
		}
		scope = payload.Scope
		pair, err = model.CreateOAuthTokenPair(
			tx, clientId, flow.UserId, scope, oauthAccessTokenTTL, oauthRefreshTokenTTL, now,
		)
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("exchange oauth authorization code: %w", ErrOAuthInvalidGrant)
	}
	if consumedCode == nil || pair == nil {
		return nil, ErrOAuthInvalidGrant
	}
	return oauthTokenResponse(pair, scope), nil
}

func CreateOAuthDeviceAuthorization(clientId, requestedScopes string, now time.Time) (*OAuthDeviceAuthorization, error) {
	if clientId != OAuthBootstrapClientId {
		return nil, ErrOAuthInvalidClient
	}
	scope, err := normalizeOAuthScopes(requestedScopes)
	if err != nil {
		return nil, err
	}
	deviceCode, userCode, grant, err := model.CreateOAuthDeviceGrant(
		clientId, scope, now.Add(oauthDeviceGrantTTL), oauthDevicePollInterval,
	)
	if err != nil {
		return nil, fmt.Errorf("create oauth device grant: %w", err)
	}
	if grant == nil {
		return nil, errors.New("create oauth device grant: missing grant")
	}
	issuer, err := OAuthIssuer()
	if err != nil {
		return nil, err
	}
	verificationURI := issuer + "/oauth/device"
	return &OAuthDeviceAuthorization{
		DeviceCode:              deviceCode,
		UserCode:                userCode,
		VerificationURI:         verificationURI,
		VerificationURIComplete: verificationURI + "?user_code=" + url.QueryEscape(userCode),
		ExpiresIn:               int(oauthDeviceGrantTTL.Seconds()),
		Interval:                oauthDevicePollInterval,
	}, nil
}

func DecideOAuthDeviceAuthorization(userCode string, userId int, approve bool, now time.Time) error {
	grant, err := model.ApproveOAuthDeviceGrant(userCode, userId, approve, now)
	if err != nil {
		return fmt.Errorf("decide oauth device authorization: %w", ErrOAuthInvalidGrant)
	}
	if grant == nil {
		return ErrOAuthInvalidGrant
	}
	return nil
}

func ExchangeOAuthDeviceCode(deviceCode, clientId string, now time.Time) (*OAuthTokenResponse, error) {
	if clientId != OAuthBootstrapClientId {
		return nil, ErrOAuthInvalidClient
	}
	var pair *model.OAuthTokenPair
	grant, err := model.ConsumeOAuthDeviceGrantWithAction(
		deviceCode, clientId, now,
		func(tx *gorm.DB, grant *model.OAuthDeviceGrant) error {
			var issueErr error
			pair, issueErr = model.CreateOAuthTokenPair(
				tx, clientId, grant.UserId, grant.Scopes,
				oauthAccessTokenTTL, oauthRefreshTokenTTL, now,
			)
			return issueErr
		},
	)
	if err != nil {
		return nil, err
	}
	return oauthTokenResponse(pair, grant.Scopes), nil
}

func ExchangeOAuthRefreshToken(refreshToken, clientId string, now time.Time) (*OAuthTokenResponse, error) {
	if clientId != OAuthBootstrapClientId {
		return nil, ErrOAuthInvalidClient
	}
	pair, err := model.RotateOAuthRefreshToken(
		refreshToken, clientId, oauthAccessTokenTTL, oauthRefreshTokenTTL, now,
	)
	if err != nil {
		return nil, fmt.Errorf("rotate oauth refresh token: %w", ErrOAuthInvalidGrant)
	}
	return oauthTokenResponse(pair, pair.Scopes), nil
}

func RevokeOAuthGrantToken(token, clientId string, now time.Time) error {
	if clientId != OAuthBootstrapClientId {
		return ErrOAuthInvalidClient
	}
	if strings.TrimSpace(token) == "" {
		return ErrOAuthInvalidRequest
	}
	if err := model.RevokeOAuthToken(token, now); err != nil {
		return fmt.Errorf("revoke oauth grant token: %w", ErrOAuthUnavailable)
	}
	return nil
}

func ValidateOAuthAccessToken(token string, requiredScopes ...string) (*model.OAuthGrantToken, error) {
	record, err := model.ValidateOAuthAccessToken(token, time.Now())
	if err != nil {
		return nil, ErrOAuthInvalidGrant
	}
	granted := make(map[string]struct{})
	for _, scope := range strings.Fields(record.Scopes) {
		granted[scope] = struct{}{}
	}
	for _, required := range requiredScopes {
		if _, ok := granted[required]; !ok {
			return nil, ErrOAuthInvalidScope
		}
	}
	return record, nil
}

func validateOAuthAuthorizationInput(input OAuthAuthorizationInput) (*oauthAuthorizationPayload, error) {
	if input.ClientId != OAuthBootstrapClientId {
		return nil, ErrOAuthInvalidClient
	}
	if input.ResponseType != "code" {
		return nil, ErrOAuthInvalidRequest
	}
	if !validOAuthRedirectURI(input.RedirectURI) {
		return nil, ErrOAuthInvalidRedirectURI
	}
	if input.CodeChallengeMethod != "S256" || !validPKCEChallenge(input.CodeChallenge) {
		return nil, ErrOAuthInvalidPKCE
	}
	if !validOAuthState(input.State) {
		return nil, ErrOAuthInvalidRequest
	}
	scope, err := normalizeOAuthScopes(input.Scope)
	if err != nil {
		return nil, err
	}
	return &oauthAuthorizationPayload{
		ClientId: input.ClientId, RedirectURI: input.RedirectURI, Scope: scope,
		State: input.State, CodeChallenge: input.CodeChallenge,
	}, nil
}

func normalizeOAuthScopes(value string) (string, error) {
	fields := strings.Fields(value)
	if len(fields) == 0 {
		return "", ErrOAuthInvalidScope
	}
	unique := make(map[string]struct{}, len(fields))
	for _, scope := range fields {
		if _, ok := oauthAllowedScopes[scope]; !ok {
			return "", ErrOAuthInvalidScope
		}
		unique[scope] = struct{}{}
	}
	fields = fields[:0]
	for scope := range unique {
		fields = append(fields, scope)
	}
	sort.Strings(fields)
	return strings.Join(fields, " "), nil
}

func validOAuthRedirectURI(value string) bool {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "http" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Path != "/oauth/callback" {
		return false
	}
	if !isLoopbackHostname(parsed.Hostname()) {
		return false
	}
	port, err := strconv.Atoi(parsed.Port())
	return err == nil && port >= 1024 && port <= 65535
}

func isLoopbackHostname(host string) bool {
	return host == "127.0.0.1" || host == "::1"
}

func validOAuthState(value string) bool {
	if len(value) < 32 || len(value) > 512 {
		return false
	}
	for _, character := range value {
		if !(character >= 'A' && character <= 'Z') &&
			!(character >= 'a' && character <= 'z') &&
			!(character >= '0' && character <= '9') &&
			!strings.ContainsRune("-._~", character) {
			return false
		}
	}
	return true
}

func validPKCEChallenge(value string) bool {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(value) == 43 && len(decoded) == sha256.Size
}

func validPKCEVerifier(value string) bool {
	if len(value) < 43 || len(value) > 128 {
		return false
	}
	for _, character := range value {
		if !(character >= 'A' && character <= 'Z') &&
			!(character >= 'a' && character <= 'z') &&
			!(character >= '0' && character <= '9') &&
			!strings.ContainsRune("-._~", character) {
			return false
		}
	}
	return true
}

func verifyPKCE(expectedChallenge, verifier string) bool {
	if !validPKCEVerifier(verifier) {
		return false
	}
	digest := sha256.Sum256([]byte(verifier))
	actual := base64.RawURLEncoding.EncodeToString(digest[:])
	return subtle.ConstantTimeCompare([]byte(actual), []byte(expectedChallenge)) == 1
}

func decodeOAuthAuthorizationPayload(raw string) (*oauthAuthorizationPayload, error) {
	var payload oauthAuthorizationPayload
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return nil, fmt.Errorf("decode oauth authorization payload: %w", ErrOAuthInvalidGrant)
	}
	return &payload, nil
}

func oauthTokenResponse(pair *model.OAuthTokenPair, scope string) *OAuthTokenResponse {
	return &OAuthTokenResponse{
		AccessToken: pair.AccessToken, TokenType: "Bearer",
		ExpiresIn: int(oauthAccessTokenTTL.Seconds()), RefreshToken: pair.RefreshToken,
		Scope: scope,
	}
}
