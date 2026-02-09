package script

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/errs"
)

func fixturesDir() string {
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "..", "testdata", "fixtures")
}

func TestRunSetupSuccess(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "setup")

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "I succeeded") {
		t.Fatalf("expected 'I succeeded' in output, got %q", output)
	}
}

func TestRunSetupFailure(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "failed_setup")

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, errs.ErrSetup) {
		t.Fatalf("expected ErrSetup, got %v", err)
	}
	if !strings.Contains(output, "I failed") {
		t.Fatalf("expected 'I failed' in output, got %q", output)
	}
}

func TestRunTeardownSuccess(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "teardown")

	output, err := Run("teardown", scriptPath, dir, "test-workroom", "/parent")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "I teared down") {
		t.Fatalf("expected 'I teared down' in output, got %q", output)
	}
}

func TestRunTeardownFailure(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "failed_teardown")

	output, err := Run("teardown", scriptPath, dir, "test-workroom", "/parent")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, errs.ErrTeardown) {
		t.Fatalf("expected ErrTeardown, got %v", err)
	}
	if !strings.Contains(output, "I failed to tear down") {
		t.Fatalf("expected 'I failed to tear down' in output, got %q", output)
	}
}

func TestRunMissingScript(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "nonexistent")

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent")
	if err != nil {
		t.Fatalf("expected no error for missing script, got %v", err)
	}
	if output != "" {
		t.Fatalf("expected empty output, got %q", output)
	}
}

func TestRunSetsEnvVars(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "env_check")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"NAME=$WORKROOM_NAME\"\necho \"PARENT=$WORKROOM_PARENT_DIR\"\n"), 0o755)

	output, err := Run("setup", scriptPath, dir, "my-workroom", "/parent/dir")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "NAME=my-workroom") {
		t.Fatalf("expected WORKROOM_NAME in output, got %q", output)
	}
	if !strings.Contains(output, "PARENT=/parent/dir") {
		t.Fatalf("expected WORKROOM_PARENT_DIR in output, got %q", output)
	}
}
