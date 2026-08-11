package common

import "testing"

func TestParseEmailRecipientsRejectsHeaderInjection(t *testing.T) {
	_, _, err := parseEmailRecipients("victim@example.com\r\nBcc: attacker@example.com")
	if err == nil {
		t.Fatal("recipient containing an injected header was accepted")
	}
}

func TestParseEmailRecipientsBuildsCanonicalHeaderAndEnvelope(t *testing.T) {
	header, recipients, err := parseEmailRecipients("first@example.com; second@example.com")
	if err != nil {
		t.Fatal(err)
	}
	if header != "<first@example.com>, <second@example.com>" {
		t.Fatalf("header = %q", header)
	}
	if len(recipients) != 2 || recipients[0] != "first@example.com" || recipients[1] != "second@example.com" {
		t.Fatalf("recipients = %#v", recipients)
	}
}
