package controller

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
