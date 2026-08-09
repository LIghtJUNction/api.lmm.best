package system_setting

import "testing"

func TestRegistrationPoliciesPublishedRequiresTrimmedOperatorContent(t *testing.T) {
	settings := GetLegalSettings()
	original := *settings
	t.Cleanup(func() { *settings = original })

	tests := []struct {
		name          string
		userAgreement string
		privacyPolicy string
		wantAgreement bool
		wantPrivacy   bool
		wantBoth      bool
	}{
		{name: "both missing"},
		{name: "agreement missing", privacyPolicy: "privacy", wantPrivacy: true},
		{name: "privacy missing", userAgreement: "terms", wantAgreement: true},
		{name: "both whitespace", userAgreement: " \n\t", privacyPolicy: "\t ", wantAgreement: false, wantPrivacy: false},
		{name: "agreement whitespace", userAgreement: " \n", privacyPolicy: "privacy", wantPrivacy: true},
		{name: "privacy whitespace", userAgreement: "terms", privacyPolicy: " \t", wantAgreement: true},
		{name: "both published", userAgreement: " terms ", privacyPolicy: "\nprivacy\n", wantAgreement: true, wantPrivacy: true, wantBoth: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			settings.UserAgreement = test.userAgreement
			settings.PrivacyPolicy = test.privacyPolicy
			if got := UserAgreementPublished(); got != test.wantAgreement {
				t.Fatalf("UserAgreementPublished() = %v, want %v", got, test.wantAgreement)
			}
			if got := PrivacyPolicyPublished(); got != test.wantPrivacy {
				t.Fatalf("PrivacyPolicyPublished() = %v, want %v", got, test.wantPrivacy)
			}
			if got := RegistrationPoliciesPublished(); got != test.wantBoth {
				t.Fatalf("RegistrationPoliciesPublished() = %v, want %v", got, test.wantBoth)
			}
		})
	}
}
