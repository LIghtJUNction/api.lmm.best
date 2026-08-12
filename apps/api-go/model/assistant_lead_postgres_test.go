package model

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRecordAssistantProfilePostgresUpsert(t *testing.T) {
	if strings.TrimSpace(os.Getenv("TEST_POSTGRES_DSN")) == "" {
		t.Skip("set TEST_POSTGRES_DSN to run PostgreSQL assistant profile integration tests")
	}
	if os.Getenv("TEST_POSTGRES_ISOLATED_SCHEMA") != "1" {
		t.Skip("set TEST_POSTGRES_ISOLATED_SCHEMA=1 to acknowledge isolated test-schema creation")
	}

	previousDB, previousLogDB := DB, LOG_DB
	db := openIsolatedPostgresCacheTestDB(t, &AssistantProfileBucket{})
	DB, LOG_DB = db, db
	usePostgresDatabaseType(t)
	t.Cleanup(func() {
		DB, LOG_DB = previousDB, previousLogDB
	})

	require.NoError(t, RecordAssistantProfile("guided_buyer"))
	require.NoError(t, RecordAssistantProfile("guided_buyer"))

	var bucket AssistantProfileBucket
	require.NoError(t, DB.Where("profile = ?", "guided_buyer").First(&bucket).Error)
	require.EqualValues(t, 2, bucket.Count)

	var summary []AssistantProfileSummary
	require.NoError(t, DB.Model(&AssistantProfileBucket{}).
		Select("profile, SUM(count) AS count").
		Group("profile").
		Scan(&summary).Error)
	require.Len(t, summary, 1)
	require.Equal(t, "guided_buyer", summary[0].Profile)
	require.EqualValues(t, 2, summary[0].Count)
}
