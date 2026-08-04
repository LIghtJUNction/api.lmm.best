package model

import (
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOpenSourceBountyMCPTokenRotationAndRevocation(t *testing.T) {
	db := setupOpenSourceBountyTestDB(t)
	require.NoError(t, db.AutoMigrate(&OpenSourceBountyMCPToken{}, &OpenSourceBountyMCPConfirmation{}, &OpenSourceBountyMCPOperation{}))
	user := createOpenSourceBountyUser(t, db, "mcp-user", 100, common.RoleCommonUser)

	first, status, err := RotateOpenSourceBountyMCPToken(user.Id)
	require.NoError(t, err)
	assert.NotEmpty(t, first)
	assert.NotContains(t, status.TokenHint, first)
	verifiedUser, err := VerifyOpenSourceBountyMCPToken(first)
	require.NoError(t, err)
	assert.Equal(t, user.Id, verifiedUser)

	second, _, err := RotateOpenSourceBountyMCPToken(user.Id)
	require.NoError(t, err)
	assert.NotEqual(t, first, second)
	_, err = VerifyOpenSourceBountyMCPToken(first)
	assert.Equal(t, "OPEN_SOURCE_BOUNTY_MCP_INVALID_TOKEN", OpenSourceBountyErrorCode(err))
	verifiedUser, err = VerifyOpenSourceBountyMCPToken(second)
	require.NoError(t, err)
	assert.Equal(t, user.Id, verifiedUser)

	tokenStatus, err := GetOpenSourceBountyMCPTokenStatus(user.Id)
	require.NoError(t, err)
	assert.True(t, tokenStatus.Configured)
	require.NoError(t, RevokeOpenSourceBountyMCPToken(user.Id))
	_, err = VerifyOpenSourceBountyMCPToken(second)
	assert.Equal(t, "OPEN_SOURCE_BOUNTY_MCP_INVALID_TOKEN", OpenSourceBountyErrorCode(err))
}

func TestOpenSourceBountyMCPConfirmationIsBoundAndSingleUse(t *testing.T) {
	db := setupOpenSourceBountyTestDB(t)
	require.NoError(t, db.AutoMigrate(&OpenSourceBountyMCPConfirmation{}))
	user := createOpenSourceBountyUser(t, db, "mcp-confirm", 100, common.RoleCommonUser)
	payloadHash, err := OpenSourceBountyMCPPayloadHash(map[string]any{"project_id": 7})
	require.NoError(t, err)
	state, err := CreateOpenSourceBountyMCPConfirmation(user.Id, "open_source_bounties.publish", payloadHash)
	require.NoError(t, err)

	wrongHash, err := OpenSourceBountyMCPPayloadHash(map[string]any{"project_id": 8})
	require.NoError(t, err)
	err = ConsumeOpenSourceBountyMCPConfirmation(user.Id, "open_source_bounties.publish", wrongHash, state)
	assert.Equal(t, "OPEN_SOURCE_BOUNTY_MCP_CONFIRMATION_INVALID", OpenSourceBountyErrorCode(err))
	err = ConsumeOpenSourceBountyMCPConfirmation(user.Id, "open_source_bounties.publish", payloadHash, state)
	assert.Equal(t, "OPEN_SOURCE_BOUNTY_MCP_CONFIRMATION_INVALID", OpenSourceBountyErrorCode(err))
}
