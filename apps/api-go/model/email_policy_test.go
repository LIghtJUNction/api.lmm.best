package model

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestIsDisposableEmailUsesExactKnownDomains(t *testing.T) {
	for _, test := range []struct {
		name  string
		email string
		want  bool
	}{
		{name: "known domain", email: "person@mailinator.com", want: true},
		{name: "case and whitespace are normalized", email: " Person@TEMPMAIL.COM ", want: true},
		{name: "lookalike domain", email: "person@mailinator.com.example", want: false},
		{name: "subdomain is not an exact match", email: "person@sub.mailinator.com", want: false},
		{name: "privacy mailbox is not disposable", email: "person@proton.me", want: false},
		{name: "missing email", email: "", want: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			assert.Equal(t, test.want, IsDisposableEmail(test.email))
		})
	}
}
