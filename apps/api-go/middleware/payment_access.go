package middleware

import (
	"net/http"

	"github.com/QuantumNous/new-api/model"
	"github.com/gin-gonic/gin"
)

func PaymentAccessGate() gin.HandlerFunc {
	return func(c *gin.Context) {
		user, err := model.GetUserById(c.GetInt("id"), false)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{
				"success": false,
				"message": "Unable to verify payment access.",
			})
			return
		}
		if model.IsPaymentRestricted(user) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
				"success": false,
				"code":    "PAYMENT_UNAVAILABLE",
				"message": "Payment is unavailable for this account.",
			})
			return
		}
		c.Next()
	}
}
