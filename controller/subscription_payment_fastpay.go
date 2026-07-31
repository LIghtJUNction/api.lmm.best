package controller

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/logger"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/service"
	"github.com/gin-gonic/gin"
)

type SubscriptionFastPayPayRequest struct {
	PlanId        int    `json:"plan_id"`
	PaymentMethod string `json:"payment_method"`
}

func SubscriptionRequestFastPay(c *gin.Context) {
	if !requirePaymentCompliance(c) {
		return
	}

	var req SubscriptionFastPayPayRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.PlanId <= 0 {
		common.ApiErrorMsg(c, "参数错误")
		return
	}

	plan, err := model.GetSubscriptionPlanById(req.PlanId)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if !plan.Enabled {
		common.ApiErrorMsg(c, "套餐未启用")
		return
	}
	if plan.PriceAmount < 0.01 {
		common.ApiErrorMsg(c, "套餐金额过低")
		return
	}

	cfg := getFastPayConfig()
	if cfg == nil {
		common.ApiErrorMsg(c, "当前管理员未配置 FAST 易支付信息")
		return
	}

	userId := c.GetInt("id")
	if plan.MaxPurchasePerUser > 0 {
		count, err := model.CountUserSubscriptionsByPlan(userId, plan.Id)
		if err != nil {
			common.ApiError(c, err)
			return
		}
		if count >= int64(plan.MaxPurchasePerUser) {
			common.ApiErrorMsg(c, "已达到该套餐购买上限")
			return
		}
	}

	callBackAddress := service.GetCallbackAddress()
	returnUrl := paymentReturnPath("/wallet?pay=success")
	notifyUrl := callBackAddress + "/api/subscription/fastpay/notify"
	tradeNo := fmt.Sprintf("SUBUSR%dNO%s%d", userId, common.GetRandomString(6), time.Now().Unix())

	order := &model.SubscriptionOrder{
		UserId:          userId,
		PlanId:          plan.Id,
		Money:           plan.PriceAmount,
		TradeNo:         tradeNo,
		PaymentMethod:   req.PaymentMethod,
		PaymentProvider: model.PaymentProviderFastPay,
		CreateTime:      time.Now().Unix(),
		Status:          common.TopUpStatusPending,
	}
	if err := order.Insert(); err != nil {
		common.ApiErrorMsg(c, "创建订单失败")
		return
	}

	params := map[string]string{
		"merchantNo": cfg.MerchantNo,
		"outTradeNo": tradeNo,
		"amount":     strconv.FormatFloat(plan.PriceAmount, 'f', 2, 64),
		"subject":    fmt.Sprintf("SUB:%s", plan.Title),
		"payType":    req.PaymentMethod,
		"notifyUrl":  notifyUrl,
		"returnUrl":  returnUrl,
		"timestamp":  strconv.FormatInt(time.Now().Unix(), 10),
	}
	params["sign"] = GenerateFastPaySign(params, cfg.ApiSecret)

	submitUrl := getFastPaySubmitUrl(cfg.Address)

	c.JSON(http.StatusOK, gin.H{"message": "success", "data": params, "url": submitUrl})
}

func SubscriptionFastPayNotify(c *gin.Context) {
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
		logger.LogWarn(c.Request.Context(), fmt.Sprintf("FAST易支付 订阅回调验签失败 outTradeNo=%s client_ip=%s", payload.OutTradeNo, c.ClientIP()))
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

	if err := model.CompleteSubscriptionOrder(payload.OutTradeNo, string(bodyBytes), model.PaymentProviderFastPay, payload.PayType); err != nil {
		_, _ = c.Writer.Write([]byte("fail"))
		return
	}

	_, _ = c.Writer.Write([]byte("success"))
}
