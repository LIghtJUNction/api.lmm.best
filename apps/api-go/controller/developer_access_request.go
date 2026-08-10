package controller

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type developerAccessRequestInput struct {
	Reason string `json:"reason"`
}

type developerAccessRequestReviewInput struct {
	Note string `json:"note"`
}

type developerAccessRequestSelfResponse struct {
	Id         int    `json:"id"`
	Status     string `json:"status"`
	Reason     string `json:"reason"`
	AdminNote  string `json:"admin_note"`
	CreatedAt  int64  `json:"created_at"`
	ReviewedAt int64  `json:"reviewed_at"`
}

func toDeveloperAccessRequestSelfResponse(request *model.DeveloperAccessRequest) any {
	if request == nil {
		return nil
	}
	return developerAccessRequestSelfResponse{
		Id:         request.Id,
		Status:     request.Status,
		Reason:     request.Reason,
		AdminNote:  request.AdminNote,
		CreatedAt:  request.CreatedAt,
		ReviewedAt: request.ReviewedAt,
	}
}

func developerAccessRequestError(c *gin.Context, status int, code string, message string) {
	c.AbortWithStatusJSON(status, gin.H{
		"success": false,
		"code":    code,
		"message": message,
	})
}

func currentDeveloperAccessUser(c *gin.Context) (*model.UserBase, error) {
	userID := c.GetInt("id")
	if userID <= 0 {
		return nil, gorm.ErrInvalidData
	}
	return model.GetUserCache(userID)
}

func GetDeveloperAccessRequest(c *gin.Context) {
	request, err := model.GetDeveloperAccessRequest(c.GetInt("id"))
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, toDeveloperAccessRequestSelfResponse(request))
}

func SubmitDeveloperAccessRequest(c *gin.Context) {
	user, err := currentDeveloperAccessUser(c)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	access, err := model.GetDeveloperAccessStateForUserBase(user)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if access.Granted {
		developerAccessRequestError(c, http.StatusConflict, "DEVELOPER_ACCESS_ALREADY_ACTIVE", "developer access is already active")
		return
	}
	var input developerAccessRequestInput
	if err := c.ShouldBindJSON(&input); err != nil {
		developerAccessRequestError(c, http.StatusUnprocessableEntity, "DEVELOPER_ACCESS_INVALID_REQUEST", "invalid unlock request")
		return
	}
	request, err := model.SubmitDeveloperAccessRequest(user.Id, input.Reason)
	if err != nil {
		if errors.Is(err, model.ErrDeveloperAccessRequestNoteTooLong) {
			developerAccessRequestError(c, http.StatusUnprocessableEntity, "DEVELOPER_ACCESS_REASON_TOO_LONG", err.Error())
			return
		}
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, toDeveloperAccessRequestSelfResponse(request))
}

func ListDeveloperAccessRequests(c *gin.Context) {
	requests, err := model.ListDeveloperAccessRequests(c.Query("status"), 100)
	if err != nil {
		if errors.Is(err, model.ErrDeveloperAccessRequestStatus) {
			developerAccessRequestError(c, http.StatusBadRequest, "DEVELOPER_ACCESS_INVALID_STATUS", "invalid request status")
			return
		}
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, requests)
}

func reviewDeveloperAccessRequest(c *gin.Context, approve bool) {
	requestID, err := strconv.Atoi(c.Param("id"))
	if err != nil || requestID <= 0 {
		developerAccessRequestError(c, http.StatusBadRequest, "DEVELOPER_ACCESS_INVALID_ID", "invalid unlock request id")
		return
	}
	var input developerAccessRequestReviewInput
	if c.Request.ContentLength != 0 {
		if err := c.ShouldBindJSON(&input); err != nil {
			developerAccessRequestError(c, http.StatusUnprocessableEntity, "DEVELOPER_ACCESS_INVALID_REQUEST", "invalid review request")
			return
		}
	}
	request, err := model.ReviewDeveloperAccessRequest(c.GetInt("id"), requestID, approve, input.Note)
	if err != nil {
		switch {
		case errors.Is(err, model.ErrDeveloperAccessRequestNotFound):
			developerAccessRequestError(c, http.StatusNotFound, "DEVELOPER_ACCESS_REQUEST_NOT_FOUND", err.Error())
		case errors.Is(err, model.ErrDeveloperAccessRequestReviewed):
			developerAccessRequestError(c, http.StatusConflict, "DEVELOPER_ACCESS_REQUEST_ALREADY_REVIEWED", err.Error())
		default:
			common.ApiError(c, err)
		}
		return
	}
	if approve {
		model.RecordLog(c.GetInt("id"), model.LogTypeSystem, "approved developer access request "+strconv.Itoa(requestID))
	} else {
		model.RecordLog(c.GetInt("id"), model.LogTypeSystem, "rejected developer access request "+strconv.Itoa(requestID))
	}
	common.ApiSuccess(c, request)
}

func ApproveDeveloperAccessRequest(c *gin.Context) {
	reviewDeveloperAccessRequest(c, true)
}

func RejectDeveloperAccessRequest(c *gin.Context) {
	reviewDeveloperAccessRequest(c, false)
}
