package controller

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/logger"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/service"
	"github.com/QuantumNous/new-api/setting"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
	"github.com/shopspring/decimal"
)

type FastPayPayRequest struct {
	Amount        int64  `json:"amount"`
	PaymentMethod string `json:"payment_method"`
}

type FastPayConfig struct {
	Address    string
	MerchantNo string
	ApiSecret  string
}

func getFastPayConfig() *FastPayConfig {
	addr := strings.TrimSpace(setting.FastPayAddress)
	merchantNo := strings.TrimSpace(setting.FastPayMerchantNo)
	secret := strings.TrimSpace(setting.FastPayApiSecret)

	// Fallback to operation_setting PayAddress/EpayId/EpayKey if PayAddress contains fastpay
	if addr == "" && strings.Contains(strings.ToLower(operation_setting.PayAddress), "fastpay") {
		addr = strings.TrimSpace(operation_setting.PayAddress)
	}
	if merchantNo == "" && strings.Contains(strings.ToLower(operation_setting.PayAddress), "fastpay") {
		merchantNo = strings.TrimSpace(operation_setting.EpayId)
	}
	if secret == "" && strings.Contains(strings.ToLower(operation_setting.PayAddress), "fastpay") {
		secret = strings.TrimSpace(operation_setting.EpayKey)
	}

	if addr == "" || merchantNo == "" || secret == "" {
		return nil
	}

	return &FastPayConfig{
		Address:    addr,
		MerchantNo: merchantNo,
		ApiSecret:  secret,
	}
}

func getFastPaySubmitUrl(rawAddr string) string {
	u := strings.TrimSuffix(strings.TrimSpace(rawAddr), "/submit.php")
	u = strings.TrimRight(u, "/")
	if !strings.HasSuffix(u, "/api/pay/submit") {
		u += "/api/pay/submit"
	}
	return u
}

// GenerateFastPaySign generates MD5 signature according to FastPay specification:
// 1. Sort all non-null params (excluding "sign") by ASCII order.
// 2. Format as key1=val1&key2=val2...
// 3. Append &key=secret.
// 4. MD5 hash and upper-case.
func GenerateFastPaySign(params map[string]string, secret string) string {
	keys := make([]string, 0, len(params))
	for k, v := range params {
		if k == "sign" || v == "" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var sb strings.Builder
	for i, k := range keys {
		if i > 0 {
			sb.WriteString("&")
		}
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(params[k])
	}
	sb.WriteString("&key=")
	sb.WriteString(secret)

	hash := md5.Sum([]byte(sb.String()))
	return strings.ToUpper(hex.EncodeToString(hash[:]))
}

func VerifyFastPaySign(params map[string]string, secret string, expectedSign string) bool {
	if secret == "" || expectedSign == "" {
		return false
	}
	sign := GenerateFastPaySign(params, secret)
	return strings.EqualFold(sign, expectedSign)
}

func RequestFastPay(c *gin.Context) {
	if !requirePaymentCompliance(c) {
		return
	}

	var req FastPayPayRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "参数错误"})
		return
	}
	if req.Amount < getMinTopup() {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": fmt.Sprintf("充值数量不能小于 %d", getMinTopup())})
		return
	}

	cfg := getFastPayConfig()
	if cfg == nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "当前管理员未配置 FAST 易支付信息"})
		return
	}

	id := c.GetInt("id")
	group, err := model.GetUserGroup(id, true)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "获取用户分组失败"})
		return
	}
	payMoney := getPayMoney(req.Amount, group)
	if payMoney < 0.01 {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "充值金额过低"})
		return
	}

	callBackAddress := service.GetCallbackAddress()
	returnUrl := paymentReturnPath("/usage-logs")
	notifyUrl := callBackAddress + "/api/user/fastpay/notify"
	tradeNo := fmt.Sprintf("USR%dNO%s%d", id, common.GetRandomString(6), time.Now().Unix())

	params := map[string]string{
		"merchantNo": cfg.MerchantNo,
		"outTradeNo": tradeNo,
		"amount":     strconv.FormatFloat(payMoney, 'f', 2, 64),
		"subject":    fmt.Sprintf("TUC%d", req.Amount),
		"payType":    req.PaymentMethod,
		"notifyUrl":  notifyUrl,
		"returnUrl":  returnUrl,
		"timestamp":  strconv.FormatInt(time.Now().Unix(), 10),
	}
	params["sign"] = GenerateFastPaySign(params, cfg.ApiSecret)

	amount := req.Amount
	if operation_setting.GetQuotaDisplayType() == operation_setting.QuotaDisplayTypeTokens {
		dAmount := decimal.NewFromInt(int64(amount))
		dQuotaPerUnit := decimal.NewFromFloat(common.QuotaPerUnit)
		amount = dAmount.Div(dQuotaPerUnit).IntPart()
	}

	topUp := &model.TopUp{
		UserId:          id,
		Amount:          amount,
		Money:           payMoney,
		TradeNo:         tradeNo,
		PaymentMethod:   req.PaymentMethod,
		PaymentProvider: model.PaymentProviderFastPay,
		CreateTime:      time.Now().Unix(),
		Status:          common.TopUpStatusPending,
	}
	if err := topUp.Insert(); err != nil {
		logger.LogError(c.Request.Context(), fmt.Sprintf("FAST易支付 创建充值订单失败 user_id=%d trade_no=%s error=%q", id, tradeNo, err.Error()))
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "创建订单失败"})
		return
	}

	submitUrl := getFastPaySubmitUrl(cfg.Address)

	c.JSON(http.StatusOK, gin.H{
		"message": "success",
		"data":    params,
		"url":     submitUrl,
	})
}

type FastPayNotifyPayload struct {
	MerchantNo string      `json:"merchantNo"`
	OrderNo    string      `json:"orderNo"`
	OutTradeNo string      `json:"outTradeNo"`
	Amount     interface{} `json:"amount"`
	PayAmount  interface{} `json:"payAmount"`
	PayType    string      `json:"payType"`
	Status     interface{} `json:"status"`
	PayTime    string      `json:"payTime"`
	Timestamp  interface{} `json:"timestamp"`
	Sign       string      `json:"sign"`
}

func FastPayNotify(c *gin.Context) {
	bodyBytes, err := io.ReadAll(c.Request.Body)
	if err != nil || len(bodyBytes) == 0 {
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	var payload FastPayNotifyPayload
	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	params := map[string]string{
		"merchantNo": payload.MerchantNo,
		"orderNo":    payload.OrderNo,
		"outTradeNo": payload.OutTradeNo,
		"amount":     fmt.Sprintf("%v", payload.Amount),
		"payAmount":  fmt.Sprintf("%v", payload.PayAmount),
		"payType":    payload.PayType,
		"status":     fmt.Sprintf("%v", payload.Status),
		"payTime":    payload.PayTime,
		"timestamp":  fmt.Sprintf("%v", payload.Timestamp),
	}

	cfg := getFastPayConfig()
	secret := ""
	if cfg != nil {
		secret = cfg.ApiSecret
	}

	if !VerifyFastPaySign(params, secret, payload.Sign) {
		logger.LogWarn(c.Request.Context(), fmt.Sprintf("FAST易支付 回调验签失败 outTradeNo=%s client_ip=%s", payload.OutTradeNo, c.ClientIP()))
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	statusStr := fmt.Sprintf("%v", payload.Status)
	if statusStr != "1" && statusStr != "SUCCESS" {
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	LockOrder(payload.OutTradeNo)
	defer UnlockOrder(payload.OutTradeNo)

	topUp := model.GetTopUpByTradeNo(payload.OutTradeNo)
	if topUp == nil {
		logger.LogWarn(c.Request.Context(), fmt.Sprintf("FAST易支付 回调订单不存在 trade_no=%s client_ip=%s", payload.OutTradeNo, c.ClientIP()))
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	if topUp.PaymentProvider != model.PaymentProviderFastPay {
		logger.LogWarn(c.Request.Context(), fmt.Sprintf("FAST易支付 订单支付网关不匹配 trade_no=%s order_provider=%s client_ip=%s", payload.OutTradeNo, topUp.PaymentProvider, c.ClientIP()))
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	if topUp.Status == common.TopUpStatusPending {
		if payload.PayType != "" {
			topUp.PaymentMethod = payload.PayType
		}
		topUp.Status = common.TopUpStatusSuccess
		if err := topUp.Update(); err != nil {
			logger.LogError(c.Request.Context(), fmt.Sprintf("FAST易支付 更新充值订单失败 trade_no=%s error=%q", topUp.TradeNo, err.Error()))
			_, _ = c.Writer.Write([]byte("fail"))
			return
		}

		dAmount := decimal.NewFromInt(int64(topUp.Amount))
		dQuotaPerUnit := decimal.NewFromFloat(common.QuotaPerUnit)
		quotaToAdd := int(dAmount.Mul(dQuotaPerUnit).IntPart())
		if err := model.IncreaseUserQuota(topUp.UserId, quotaToAdd, true); err != nil {
			logger.LogError(c.Request.Context(), fmt.Sprintf("FAST易支付 更新用户额度失败 trade_no=%s error=%q", topUp.TradeNo, err.Error()))
			_, _ = c.Writer.Write([]byte("fail"))
			return
		}

		logger.LogInfo(c.Request.Context(), fmt.Sprintf("FAST易支付 充值成功 trade_no=%s user_id=%d quota_to_add=%d money=%.2f", topUp.TradeNo, topUp.UserId, quotaToAdd, topUp.Money))
		model.RecordTopupLog(topUp.UserId, fmt.Sprintf("使用在线充值成功，充值金额: %v，支付金额：%f", logger.LogQuota(quotaToAdd), topUp.Money), c.ClientIP(), topUp.PaymentMethod, "fastpay")
	}

	_, _ = c.Writer.Write([]byte("success"))
}
