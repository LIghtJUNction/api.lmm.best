package controller

import (
	"net/http"
	"strconv"

	"github.com/LIghtJUNction/api.lmm.best/common"
	"github.com/LIghtJUNction/api.lmm.best/model"
	"github.com/gin-gonic/gin"
)

func GetReferralLedger(c *gin.Context) {
	before, err := strconv.ParseUint(c.DefaultQuery("before_id", "0"), 10, 32)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	items, err := model.ListReferralLedger(c.GetInt("id"), uint(before), 20)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	user, err := model.GetUserById(c.GetInt("id"), false)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	var next uint
	if len(items) == 20 {
		next = items[len(items)-1].ID
	}
	c.JSON(http.StatusOK, gin.H{"success": true, "data": gin.H{
		"items": items, "next_before_id": next, "balance": user.AffQuota,
		"debt": user.AffDebt, "policy": model.ReferralPolicySnapshot(),
	}})
}

func BanUserForReferralAbuse(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil || id <= 0 {
		common.ApiErrorMsg(c, "invalid user id")
		return
	}
	var req model.ReferralBanInput
	if err := c.ShouldBindJSON(&req); err != nil {
		common.ApiError(c, err)
		return
	}
	// Neither the target nor the actor can be overridden in the JSON body.
	req.UserID, req.ActorID = id, c.GetInt("id")
	result, err := model.BanReferralInvitee(req)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	recordManageAuditFor(c, id, "user.referral_abuse_ban", map[string]interface{}{
		"case_id": result.ID, "reason": result.Reason, "reclaimed_quota": result.ReclaimedQuota,
		"penalty_quota": result.PenaltyQuota, "restored_at": result.RestoredAt,
	})
	c.JSON(http.StatusOK, gin.H{"success": true, "data": result})
}

func RestoreUserReferralBan(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	caseID, caseErr := strconv.ParseUint(c.Param("case_id"), 10, 32)
	if err != nil || caseErr != nil || id <= 0 || caseID == 0 {
		common.ApiErrorMsg(c, "invalid referral case")
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		common.ApiError(c, err)
		return
	}
	result, err := model.RestoreReferralBan(uint(caseID), id, c.GetInt("id"), req.Reason)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	recordManageAuditFor(c, id, "user.referral_abuse_restore", map[string]interface{}{"case_id": result.ID})
	c.JSON(http.StatusOK, gin.H{"success": true, "data": result})
}
