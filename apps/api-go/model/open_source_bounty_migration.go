package model

const legacyOpenSourceBountyParticipantIndex = "idx_open_source_bounty_participant"

// The original unique project/participant index prevented contributors from
// retaining a rejected attempt and starting a later retry.
func migrateOpenSourceBountyChallengeRetryIndex() error {
	if !DB.Migrator().HasTable(&OpenSourceBountyChallenge{}) ||
		!DB.Migrator().HasIndex(&OpenSourceBountyChallenge{}, legacyOpenSourceBountyParticipantIndex) {
		return nil
	}
	return DB.Migrator().DropIndex(&OpenSourceBountyChallenge{}, legacyOpenSourceBountyParticipantIndex)
}
