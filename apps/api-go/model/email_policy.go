package model

import "strings"

// disposableEmailDomains is an explicit list of well-known throwaway mailbox
// domains. It is a promotion-abuse signal, not an account validity decision:
// disposable-mail users may still use ordinary account features and request
// administrator review.
var disposableEmailDomains = map[string]struct{}{
	"10minutemail.com":   {},
	"disposablemail.com": {},
	"emailondeck.com":    {},
	"fakeinbox.com":      {},
	"getnada.com":        {},
	"guerrillamail.com":  {},
	"maildrop.cc":        {},
	"mailinator.com":     {},
	"sharklasers.com":    {},
	"tempmail.com":       {},
	"temp-mail.org":      {},
	"yopmail.com":        {},
}

// IsDisposableEmail reports whether email belongs to a known throwaway
// mailbox domain. Matching is exact so a lookalike or subdomain is not
// accidentally classified as disposable.
func IsDisposableEmail(email string) bool {
	email = NormalizeEmail(email)
	at := strings.LastIndexByte(email, '@')
	if at <= 0 || at == len(email)-1 {
		return false
	}
	_, found := disposableEmailDomains[email[at+1:]]
	return found
}
