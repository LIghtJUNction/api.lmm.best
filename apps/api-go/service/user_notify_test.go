package service

import (
	"strings"
	"testing"
)

func TestRenderEmailNotificationEscapesValuesButPreservesTemplateMarkup(t *testing.T) {
	content := renderEmailNotification(
		`Quota low.<br/>Recharge: <a href="{{value}}">{{value}}</a>`,
		[]interface{}{`https://example.com/' onclick='alert(1)`, `<script>alert(1)</script>`},
	)

	if !strings.Contains(content, `<a href="https://example.com/&#39; onclick=&#39;alert(1)">`) {
		t.Fatalf("trusted template markup was not preserved: %s", content)
	}
	if strings.Contains(content, "<script>") || !strings.Contains(content, "&lt;script&gt;") {
		t.Fatalf("notification value was not escaped: %s", content)
	}
}
