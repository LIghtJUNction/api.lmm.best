package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPackagedFrontendServesAssetsAndSPAFallback(t *testing.T) {
	root := t.TempDir()
	assets := filepath.Join(root, "assets")
	if err := os.Mkdir(assets, 0o755); err != nil {
		t.Fatal(err)
	}
	static := filepath.Join(root, "static", "js")
	if err := os.MkdirAll(static, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte("spa-index"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assets, "app.js"), []byte("asset-js"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(static, "app.js"), []byte("static-js"), 0o644); err != nil {
		t.Fatal(err)
	}
	handler, err := newFrontendHandler(root)
	if err != nil {
		t.Fatal(err)
	}

	for _, test := range []struct {
		path       string
		wantStatus int
		wantBody   string
	}{
		{path: "/", wantStatus: http.StatusOK, wantBody: "spa-index"},
		{path: "/dashboard/models", wantStatus: http.StatusOK, wantBody: "spa-index"},
		{path: "/assets/app.js", wantStatus: http.StatusOK, wantBody: "asset-js"},
		{path: "/assets/missing.js", wantStatus: http.StatusNotFound, wantBody: "404 page not found"},
		{path: "/static/js/app.js", wantStatus: http.StatusOK, wantBody: "static-js"},
		{path: "/static/js/missing.js", wantStatus: http.StatusNotFound, wantBody: "404 page not found"},
	} {
		t.Run(test.path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, test.path, nil)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			result := response.Result()
			defer result.Body.Close()
			body, readErr := io.ReadAll(result.Body)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if result.StatusCode != test.wantStatus || !strings.Contains(string(body), test.wantBody) {
				t.Fatalf("status/body = %d/%q, want %d containing %q", result.StatusCode, body, test.wantStatus, test.wantBody)
			}
		})
	}
}

func TestPackagedFrontendRejectsRelativeAndSymlinkedRoots(t *testing.T) {
	if _, err := newFrontendHandler("relative/frontend"); err == nil {
		t.Fatal("relative frontend root was accepted")
	}

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte("index"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "frontend-link")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	if _, err := newFrontendHandler(link); err == nil {
		t.Fatal("symlinked frontend root was accepted")
	}
}
