/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
package controller

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
	"github.com/shopspring/decimal"
)

const paymentMethodMaxTopUpKey = "max_topup"

// configuredPaymentMethodMaxTopUp returns the most restrictive configured
// limit when duplicate catalog entries share a payment type. Checkout only
// carries the type, so choosing the smallest limit prevents a duplicate entry
// from weakening the server-side policy.
func configuredPaymentMethodMaxTopUp(paymentType string) (decimal.Decimal, bool, error) {
	paymentType = strings.TrimSpace(paymentType)
	var limit decimal.Decimal
	configured := false

	for _, method := range operation_setting.PayMethods {
		if strings.TrimSpace(method["type"]) != paymentType {
			continue
		}

		rawLimit, exists := method[paymentMethodMaxTopUpKey]
		rawLimit = strings.TrimSpace(rawLimit)
		if !exists || rawLimit == "" {
			continue
		}
		if !positiveDecimalPattern.MatchString(rawLimit) {
			return decimal.Zero, true, fmt.Errorf("payment method %q has invalid %s", paymentType, paymentMethodMaxTopUpKey)
		}
		parsed, err := decimal.NewFromString(rawLimit)
		if err != nil || !parsed.IsPositive() {
			return decimal.Zero, true, fmt.Errorf("payment method %q has invalid %s", paymentType, paymentMethodMaxTopUpKey)
		}
		if !configured || parsed.LessThan(limit) {
			limit = parsed
			configured = true
		}
	}

	return limit, configured, nil
}

func requestedTopUpUSD(amount int64) decimal.Decimal {
	requested := decimal.NewFromInt(amount)
	if operation_setting.GetQuotaDisplayType() == operation_setting.QuotaDisplayTypeTokens {
		return requested.Div(decimal.NewFromFloat(common.QuotaPerUnit))
	}
	return requested
}

func creditedQuotaUSD(quota int64) decimal.Decimal {
	return decimal.NewFromInt(quota).Div(decimal.NewFromFloat(common.QuotaPerUnit))
}

func requirePaymentMethodTopUpWithinLimit(c *gin.Context, paymentType string, amount int64) bool {
	return requirePaymentMethodUSDWithinLimit(c, paymentType, requestedTopUpUSD(amount))
}

func requirePaymentMethodCreditedQuotaWithinLimit(c *gin.Context, paymentType string, quota int64) bool {
	return requirePaymentMethodUSDWithinLimit(c, paymentType, creditedQuotaUSD(quota))
}

func requirePaymentMethodUSDWithinLimit(c *gin.Context, paymentType string, amount decimal.Decimal) bool {
	limit, configured, err := configuredPaymentMethodMaxTopUp(paymentType)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "error", "data": "支付方式配置无效"})
		return false
	}
	if !configured || !amount.GreaterThan(limit) {
		return true
	}
	c.JSON(http.StatusOK, gin.H{
		"message": "error",
		"data":    fmt.Sprintf("该支付方式单笔最多充值 %s 美元到账余额", limit.String()),
	})
	return false
}
