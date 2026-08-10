package appcli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeProductionHardenAtomicallyPinsSecurityAndMemoryGuards(t *testing.T) {
	root := t.TempDir()
	envFile := filepath.Join(root, "etc", "lmm-api-go.env")
	dropInDir := filepath.Join(root, "systemd", "lmm-api-go.service.d")
	if err := os.MkdirAll(filepath.Dir(envFile), 0o700); err != nil {
		t.Fatal(err)
	}
	original := "SQL_DSN=postgres://private\nSESSION_COOKIE_SECURE=false\nTRUSTED_PROXIES=0.0.0.0/0\n"
	if err := os.WriteFile(envFile, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := RunDeploy([]string{
		"production", "harden", "--env-file", envFile, "--drop-in-dir", dropInDir,
	}, &stdout, &stderr)
	if code != ExitOK {
		t.Fatalf("harden exit=%d stderr=%q", code, stderr.String())
	}
	environment, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"SQL_DSN=postgres://private",
		"SESSION_COOKIE_SECURE=true",
		"SESSION_COOKIE_TRUSTED_URL=https://api.lmm.best",
		"TRUSTED_PROXIES=127.0.0.1/32,::1/128",
	} {
		if !strings.Contains(string(environment), expected) {
			t.Errorf("environment missing %q: %q", expected, environment)
		}
	}
	if strings.Contains(string(environment), "SESSION_COOKIE_SECURE=false") || strings.Contains(string(environment), "0.0.0.0/0") {
		t.Fatalf("unsafe values survived hardening: %q", environment)
	}
	envInfo, err := os.Stat(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if envInfo.Mode().Perm() != 0o600 {
		t.Fatalf("environment mode=%v", envInfo.Mode().Perm())
	}

	memoryPath := filepath.Join(dropInDir, productionMemoryFileName)
	memory, err := os.ReadFile(memoryPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"MemoryHigh=320M", "MemoryMax=384M", "MemorySwapMax=256M"} {
		if !strings.Contains(string(memory), expected) {
			t.Errorf("memory guard missing %q: %q", expected, memory)
		}
	}
	memoryInfo, err := os.Stat(memoryPath)
	if err != nil {
		t.Fatal(err)
	}
	if memoryInfo.Mode().Perm() != 0o644 {
		t.Fatalf("memory drop-in mode=%v", memoryInfo.Mode().Perm())
	}
	if stdout.String() != "configuration=hardened\nsystemd_reload_required=true\n" {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestNativeProductionHardenRejectsSymlinkedSensitiveTargets(t *testing.T) {
	root := t.TempDir()
	realEnv := filepath.Join(root, "real.env")
	linkEnv := filepath.Join(root, "link.env")
	if err := os.WriteFile(realEnv, []byte("SQL_DSN=private\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realEnv, linkEnv); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	code := RunDeploy([]string{
		"production", "harden", "--env-file", linkEnv, "--drop-in-dir", filepath.Join(root, "dropins"),
	}, &bytes.Buffer{}, &stderr)
	if code == ExitOK || !strings.Contains(stderr.String(), "real regular file") {
		t.Fatalf("symlink harden exit=%d stderr=%q", code, stderr.String())
	}
	content, err := os.ReadFile(realEnv)
	if err != nil || string(content) != "SQL_DSN=private\n" {
		t.Fatalf("real env changed: %q err=%v", content, err)
	}
}
