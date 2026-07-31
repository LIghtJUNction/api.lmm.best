package controller

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/setting"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
)

func TestFastPaySignAndVerify(t *testing.T) {
	secret := "MY_SECRET_KEY_123"
	params := map[string]string{
		"merchantNo": "M12345678",
		"outTradeNo": "ORDER202512050001",
		"amount":     "10.00",
		"subject":    "测试商品",
		"payType":    "wxpay",
		"timestamp":  "1733400000",
	}

	sign := GenerateFastPaySign(params, secret)
	assert.NotEmpty(t, sign)
	assert.True(t, VerifyFastPaySign(params, secret, sign))
	assert.False(t, VerifyFastPaySign(params, secret, "WRONG_SIGN"))
}

func TestFastPayNotify_InvalidSign(t *testing.T) {
	gin.SetMode(gin.TestMode)
	oldAddress := setting.FastPayAddress
	oldMerchantNo := setting.FastPayMerchantNo
	oldShopNo := setting.FastPayShopNo
	oldApiSecret := setting.FastPayApiSecret
	t.Cleanup(func() {
		setting.FastPayAddress = oldAddress
		setting.FastPayMerchantNo = oldMerchantNo
		setting.FastPayShopNo = oldShopNo
		setting.FastPayApiSecret = oldApiSecret
	})
	setting.FastPayAddress = "https://pay.example.com/fastpay-server"
	setting.FastPayMerchantNo = "M12345678"
	setting.FastPayShopNo = "S12345678"
	setting.FastPayApiSecret = "secret123"

	payload := FastPayNotifyPayload{
		MerchantNo: "M12345678",
		OrderNo:    "FP123",
		OutTradeNo: "USR1NO123",
		Amount:     "10.00",
		PayAmount:  "10.00",
		PayType:    "alipay",
		Status:     1,
		PayTime:    "2026-07-31 15:00:00",
		Timestamp:  time.Now().Unix(),
		Sign:       "invalid_sign",
	}

	bodyBytes, _ := json.Marshal(payload)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/user/fastpay/notify", bytes.NewBuffer(bodyBytes))

	FastPayNotify(c)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "fail", w.Body.String())
}

func TestBuildFastPayOrderParamsMatchesServerContract(t *testing.T) {
	cfg := &FastPayConfig{
		Address:    "https://pay.example.com/fastpay-server",
		MerchantNo: "M12345678",
		ShopNo:     "S12345678",
		ApiSecret:  "secret123",
	}

	params := buildFastPayOrderParams(
		cfg,
		"ORDER202607310001",
		"10.00",
		"测试商品",
		"alipay",
		"https://api.example.com/usage-logs",
		1785489235,
	)

	assert.Equal(t, cfg.MerchantNo, params["merchantNo"])
	assert.Equal(t, cfg.ShopNo, params["shopNo"])
	assert.NotContains(t, params, "notifyUrl")
	assert.True(t, VerifyFastPaySign(params, cfg.ApiSecret, params["sign"]))
}

func TestReadFastPayNotifyPayload_Form(t *testing.T) {
	gin.SetMode(gin.TestMode)
	secret := "secret123"
	signParams := map[string]string{
		"merchantNo": "M12345678",
		"orderNo":    "FP123",
		"outTradeNo": "USR1NO123",
		"amount":     "10.00",
		"payAmount":  "10.00",
		"payType":    "alipay",
		"status":     "1",
		"payTime":    "2026-07-31T15:00:00",
		"timestamp":  "1785489235",
	}
	form := url.Values{
		"merchantNo": {"M12345678"},
		"orderNo":    {"FP123"},
		"outTradeNo": {"USR1NO123"},
		"amount":     {"10.00"},
		"payAmount":  {"10.00"},
		"payType":    {"alipay"},
		"status":     {"1"},
		"payTime":    {"2026-07-31T15:00:00"},
		"timestamp":  {"1785489235"},
		"sign":       {GenerateFastPaySign(signParams, secret)},
	}

	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/api/user/fastpay/notify", strings.NewReader(form.Encode()))
	c.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	payload, rawBody, err := readFastPayNotifyPayload(c)

	assert.NoError(t, err)
	assert.Equal(t, "M12345678", payload.MerchantNo)
	assert.Equal(t, "USR1NO123", payload.OutTradeNo)
	assert.Equal(t, "1", payload.Status)
	assert.True(t, VerifyFastPaySign(fastPayNotifySignParams(payload), secret, payload.Sign))
	assert.Equal(t, form.Encode(), string(rawBody))
}

func TestGetFastPayConfigRequiresShopNo(t *testing.T) {
	oldAddress := setting.FastPayAddress
	oldMerchantNo := setting.FastPayMerchantNo
	oldShopNo := setting.FastPayShopNo
	oldApiSecret := setting.FastPayApiSecret
	t.Cleanup(func() {
		setting.FastPayAddress = oldAddress
		setting.FastPayMerchantNo = oldMerchantNo
		setting.FastPayShopNo = oldShopNo
		setting.FastPayApiSecret = oldApiSecret
	})

	setting.FastPayAddress = "https://pay.example.com/fastpay-server"
	setting.FastPayMerchantNo = "M12345678"
	setting.FastPayShopNo = ""
	setting.FastPayApiSecret = "secret123"
	assert.Nil(t, getFastPayConfig())

	setting.FastPayShopNo = "S12345678"
	assert.Equal(t, "S12345678", getFastPayConfig().ShopNo)
}

func TestIsSubscriptionFastPayTradeNo(t *testing.T) {
	assert.True(t, isSubscriptionFastPayTradeNo("SUBUSR1NO123"))
	assert.False(t, isSubscriptionFastPayTradeNo("USR1NO123"))
}

func TestGetFastPaySubmitUrl(t *testing.T) {
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server"))
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server/submit.php"))
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server/api/pay/submit"))
}
