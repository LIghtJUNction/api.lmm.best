package controller

import (
	"strings"
	"testing"
)

func TestBuildPasswordResetEmailContentEscapesAttributesAndQueryValues(t *testing.T) {
	content, err := buildPasswordResetEmailContent(
		"https://panel.example.com/base",
		`<img src=x onerror=alert(1)>`,
		"alice'o@example.com",
		"token&next=attacker",
		10,
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, unsafe := range []string{"<img", "alice'o@example.com", "token&next=attacker", "href='"} {
		if strings.Contains(content, unsafe) {
			t.Fatalf("email content contains unsafe fragment %q: %s", unsafe, content)
		}
	}
	for _, safe := range []string{"&lt;img", "alice%27o%40example.com", "token%26next%3Dattacker", `href="https://panel.example.com/base/user/reset?`} {
		if !strings.Contains(content, safe) {
			t.Fatalf("email content is missing safe fragment %q: %s", safe, content)
		}
	}
}

func TestBuildPasswordResetEmailContentRejectsExecutableServerAddress(t *testing.T) {
	if _, err := buildPasswordResetEmailContent("javascript:alert(1)", "LMM", "user@example.com", "token", 10); err == nil {
		t.Fatal("executable server address was accepted")
	}
}
