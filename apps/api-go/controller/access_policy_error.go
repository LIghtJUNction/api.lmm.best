package controller

import (
	"html/template"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const accessPolicyErrorHeader = "access-policy"

// GetAccessPolicyErrorPage renders the edge-policy response through the Go
// service so the user-facing error page is versioned with the application.
// Nginx is the only caller: the handler rejects public requests and never
// reflects request headers or addresses into the response.
func GetAccessPolicyErrorPage(c *gin.Context) {
	if !loopbackPeer(c.Request.RemoteAddr) ||
		strings.TrimSpace(c.GetHeader("X-LMM-Internal-Error")) != accessPolicyErrorHeader ||
		strings.TrimSpace(c.GetHeader("X-LMM-CN-Source")) != "1" {
		c.Status(http.StatusNotFound)
		return
	}

	language := "zh"
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(c.GetHeader("Accept-Language"))), "en") {
		language = "en"
	}
	page := accessPolicyErrorPage(language)
	c.Header("Cache-Control", "private, no-store, max-age=0")
	c.Header("Pragma", "no-cache")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Data(http.StatusUnavailableForLegalReasons, "text/html; charset=utf-8", []byte(page))
}

func accessPolicyErrorPage(language string) string {
	const pageTemplate = `<!doctype html>
<html lang="{{.Language}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{{.Title}}</title>
  <style>
    :root{color-scheme:dark;--bg:#111311;--panel:#1d211e;--line:#3b433d;--text:#f0f2eb;--muted:#b7beb6;--accent:#a8d5b5}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:24px}
    main{width:min(620px,100%);padding:38px;border:1px solid var(--line);border-radius:18px;background:linear-gradient(145deg,var(--panel),#161916);box-shadow:0 20px 70px #0008}
    .mark{width:12px;height:12px;border-radius:50%;background:var(--accent);margin-bottom:22px;box-shadow:0 0 0 8px #a8d5b51c}
    h1{font-size:clamp(24px,5vw,36px);line-height:1.2;margin:0 0 16px}p{margin:0 0 12px;color:var(--muted)}small{display:block;margin-top:24px;color:#8f9990}
  </style>
</head>
<body><main><div class="mark" aria-hidden="true"></div><h1>{{.Title}}</h1><p>{{.Message}}</p><p>{{.Hint}}</p><small>{{.Footer}}</small></main></body>
</html>`
	templateData := struct {
		Language string
		Title    string
		Message  string
		Hint     string
		Footer   string
	}{Language: language}
	if language == "en" {
		templateData.Title = "Direct access is not available"
		templateData.Message = "This network cannot access the service directly right now."
		templateData.Hint = "If you believe this is an error, sign in with an eligible account or contact support."
		templateData.Footer = "Request access policy · lmm.best"
	} else {
		templateData.Title = "当前网络暂不支持直接访问"
		templateData.Message = "此网络暂时无法直接访问服务。"
		templateData.Hint = "如果你认为这是误判，请使用符合条件的账号登录后重试，或联系客户支持。"
		templateData.Footer = "访问策略提示 · lmm.best"
	}
	template := template.Must(template.New("access-policy-error").Parse(pageTemplate))
	var rendered strings.Builder
	if err := template.Execute(&rendered, templateData); err != nil {
		// The template is a package constant; keep a safe response even if a
		// future edit accidentally makes it invalid.
		return "<!doctype html><meta charset=\"utf-8\"><title>Access unavailable</title>"
	}
	return rendered.String()
}
