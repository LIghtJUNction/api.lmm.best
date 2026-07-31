package controller

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/setting"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func preservePaymentGatewaySettings(t *testing.T) {
	t.Helper()
	originalFastPayAddress := setting.FastPayAddress
	originalFastPayMerchantNo := setting.FastPayMerchantNo
	originalFastPayAPISecret := setting.FastPayApiSecret
	originalPayAddress := operation_setting.PayAddress
	originalEpayID := operation_setting.EpayId
	originalEpayKey := operation_setting.EpayKey
	originalPayMethods := operation_setting.PayMethods
	t.Cleanup(func() {
		setting.FastPayAddress = originalFastPayAddress
		setting.FastPayMerchantNo = originalFastPayMerchantNo
		setting.FastPayApiSecret = originalFastPayAPISecret
		operation_setting.PayAddress = originalPayAddress
		operation_setting.EpayId = originalEpayID
		operation_setting.EpayKey = originalEpayKey
		operation_setting.PayMethods = originalPayMethods
	})
}

func TestResolveFastPayMethod_WhenOnlyFastPayIsConfigured(t *testing.T) {
	preservePaymentGatewaySettings(t)
	setting.FastPayAddress = "https://fastpay.example.com/fastpay-server"
	setting.FastPayMerchantNo = "M123"
	setting.FastPayApiSecret = "fastpay_secret"
	operation_setting.PayAddress = "https://pay.example.com"
	operation_setting.EpayId = "10001"
	operation_setting.EpayKey = ""

	method, ok := resolveFastPayMethod("alipay")
	require.True(t, ok)
	require.Equal(t, "alipay", method)
}

func TestResolveFastPayMethod_PrefixedMethodWinsWhenBothGatewaysAreConfigured(t *testing.T) {
	preservePaymentGatewaySettings(t)
	setting.FastPayAddress = "https://fastpay.example.com/fastpay-server"
	setting.FastPayMerchantNo = "M123"
	setting.FastPayApiSecret = "fastpay_secret"
	operation_setting.PayAddress = "https://epay.example.com"
	operation_setting.EpayId = "10001"
	operation_setting.EpayKey = "epay_secret"

	method, ok := resolveFastPayMethod("fastpay_wxpay")
	require.True(t, ok)
	require.Equal(t, "wxpay", method)

	method, ok = resolveFastPayMethod("alipay")
	require.False(t, ok)
	require.Equal(t, "alipay", method)
}

func TestGetTopUpInfo_EnablesOnlineTopUpWhenOnlyFastPayIsConfigured(t *testing.T) {
	gin.SetMode(gin.TestMode)
	confirmPaymentComplianceForTest(t)
	preservePaymentGatewaySettings(t)
	setting.FastPayAddress = "https://fastpay.example.com/fastpay-server"
	setting.FastPayMerchantNo = "M123"
	setting.FastPayApiSecret = "fastpay_secret"
	operation_setting.PayAddress = "https://pay.example.com"
	operation_setting.EpayId = "10001"
	operation_setting.EpayKey = ""
	operation_setting.PayMethods = []map[string]string{{"name": "支付宝", "type": "alipay"}}

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	GetTopUpInfo(c)

	var response struct {
		Data struct {
			EnableOnlineTopUp bool `json:"enable_online_topup"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &response))
	require.True(t, response.Data.EnableOnlineTopUp)
}

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

func TestGetFastPaySubmitUrl(t *testing.T) {
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server"))
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server/submit.php"))
	assert.Equal(t, "https://api.lmm.best:9443/fastpay-server/api/pay/submit", getFastPaySubmitUrl("https://api.lmm.best:9443/fastpay-server/api/pay/submit"))
}
