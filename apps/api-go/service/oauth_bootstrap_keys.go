package service

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/LIghtJUNction/api.lmm.best/setting/operation_setting"
)

var (
	ErrOAuthAPIKeyLimit    = errors.New("oauth api key limit reached")
	ErrOAuthAPIKeyName     = errors.New("invalid oauth api key name")
	ErrOAuthAPIKeyNotFound = errors.New("oauth api key not found")
)

type OAuthBootstrapAPIKey struct {
	Id           int    `json:"id"`
	Name         string `json:"name"`
	Status       int    `json:"status"`
	CreatedTime  int64  `json:"created_time"`
	AccessedTime int64  `json:"accessed_time"`
	ExpiredTime  int64  `json:"expired_time"`
	Group        string `json:"group"`
}

type OAuthBootstrapAPIKeySecret struct {
	OAuthBootstrapAPIKey
	Key string `json:"key"`
}

func ListOAuthBootstrapAPIKeys(userId int) ([]OAuthBootstrapAPIKey, error) {
	if userId <= 0 {
		return nil, ErrOAuthAPIKeyNotFound
	}
	tokens, err := model.GetAllUserTokens(userId, 0, operation_setting.GetMaxUserTokens())
	if err != nil {
		return nil, fmt.Errorf("list oauth bootstrap api keys: %w", err)
	}
	result := make([]OAuthBootstrapAPIKey, 0, len(tokens))
	for _, token := range tokens {
		if token != nil {
			result = append(result, oauthBootstrapAPIKey(*token))
		}
	}
	return result, nil
}

func CreateOAuthBootstrapAPIKey(userId int, name string, now time.Time) (*OAuthBootstrapAPIKeySecret, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "lmm-api-rs " + now.UTC().Format("2006-01-02")
	}
	if len([]rune(name)) > 50 {
		return nil, ErrOAuthAPIKeyName
	}
	key, err := common.GenerateKey()
	if err != nil {
		return nil, fmt.Errorf("generate oauth bootstrap api key: %w", err)
	}
	timestamp := now.Unix()
	token := model.Token{
		UserId: userId, Name: name, Key: key,
		CreatedTime: timestamp, AccessedTime: timestamp, ExpiredTime: -1,
		UnlimitedQuota: true, Group: "default", CrossGroupRetry: false,
	}
	if err := model.InsertTokenWithinLimitAndActivateConsole(&token, operation_setting.GetMaxUserTokens()); err != nil {
		if errors.Is(err, model.ErrUserTokenLimitReached) {
			return nil, ErrOAuthAPIKeyLimit
		}
		return nil, fmt.Errorf("create oauth bootstrap api key: %w", err)
	}
	return &OAuthBootstrapAPIKeySecret{
		OAuthBootstrapAPIKey: oauthBootstrapAPIKey(token),
		Key:                  token.GetFullKey(),
	}, nil
}

func RevealOAuthBootstrapAPIKey(userId, tokenId int) (*OAuthBootstrapAPIKeySecret, error) {
	token, err := model.GetTokenByIds(tokenId, userId)
	if err != nil {
		return nil, ErrOAuthAPIKeyNotFound
	}
	return &OAuthBootstrapAPIKeySecret{
		OAuthBootstrapAPIKey: oauthBootstrapAPIKey(*token),
		Key:                  token.GetFullKey(),
	}, nil
}

func oauthBootstrapAPIKey(token model.Token) OAuthBootstrapAPIKey {
	return OAuthBootstrapAPIKey{
		Id: token.Id, Name: token.Name, Status: token.Status,
		CreatedTime: token.CreatedTime, AccessedTime: token.AccessedTime,
		ExpiredTime: token.ExpiredTime, Group: token.Group,
	}
}
