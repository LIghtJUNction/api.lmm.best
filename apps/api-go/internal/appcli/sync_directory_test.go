package appcli

import (
	"path/filepath"
	"testing"
)

func TestSyncDirectory(t *testing.T) {
	if err := syncDirectory(t.TempDir()); err != nil {
		t.Fatalf("syncDirectory() error = %v", err)
	}
}

func TestSyncDirectoryRejectsMissingPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing")
	if err := syncDirectory(path); err == nil {
		t.Fatal("syncDirectory() accepted a missing path")
	}
}
