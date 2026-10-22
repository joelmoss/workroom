package script

import (
	"bytes"
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

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent", nil)
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

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent", nil)
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

func TestRunTeardownFailure(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "failed_teardown")

	output, err := Run("teardown", scriptPath, dir, "test-workroom", "/parent", nil)
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

	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent", nil)
	if err != nil {
		t.Fatalf("expected no error for missing script, got %v", err)
	}
	if output != "" {
		t.Fatalf("expected empty output, got %q", output)
	}
}

func TestRunStreamsToWriterAndCaptures(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "setup")

	var streamed bytes.Buffer
	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent", &streamed)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(streamed.String(), "I succeeded") {
		t.Fatalf("expected streamed output, got %q", streamed.String())
	}
	if streamed.String() != output {
		t.Fatalf("streamed output %q should equal returned output %q", streamed.String(), output)
	}
}

func TestRunFailureWithStreamOmitsOutputFromError(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(fixturesDir(), "failed_setup")

	var streamed bytes.Buffer
	output, err := Run("setup", scriptPath, dir, "test-workroom", "/parent", &streamed)
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, errs.ErrSetup) {
		t.Fatalf("expected ErrSetup, got %v", err)
	}
	// Output streamed live, so it must not be duplicated in the error message.
	if strings.Contains(err.Error(), "I failed") {
		t.Fatalf("error should not embed already-streamed output, got %q", err.Error())
	}
	// It is still captured in the return value and delivered to the stream.
	if !strings.Contains(output, "I failed") || !strings.Contains(streamed.String(), "I failed") {
		t.Fatalf("expected captured+streamed output, got output=%q streamed=%q", output, streamed.String())
	}
}

// The setup and teardown contract a local workroom's script sees: testdata/script-env's fixture,
// whose expected output for a remote workroom (remote.txt) the daemon's run-script tests check.
func TestRunMatchesTheScriptContract(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	contract := filepath.Join(fixturesDir(), "..", "script-env")
	want, err := os.ReadFile(filepath.Join(contract, "local.txt"))
	if err != nil {
		t.Fatal(err)
	}

	output, err := Run("setup", filepath.Join(contract, "workroom_script"), dir, "contract", "/the/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expected := strings.NewReplacer("{DIR}", dir, "{ROOT}", "/the/root").Replace(string(want))
	if output != expected {
		t.Fatalf("the script saw\n%s\nwant\n%s", output, expected)
	}
}

// A script that can't start (here, no execute bit) fails as the script, setup or teardown alike, so
// the CLI reports it as SetupScriptFailed/TeardownScriptFailed (exit 5), not an internal error.
func TestRunScriptThatCannotStartIsTheScriptsFailure(t *testing.T) {
	for _, tc := range []struct {
		scriptType string
		sentinel   error
	}{
		{"setup", errs.ErrSetup},
		{"teardown", errs.ErrTeardown},
	} {
		t.Run(tc.scriptType, func(t *testing.T) {
			dir := t.TempDir()
			scriptPath := filepath.Join(dir, "workroom_"+tc.scriptType)
			if err := os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho hi\n"), 0o644); err != nil {
				t.Fatal(err)
			}

			_, err := Run(tc.scriptType, scriptPath, dir, "my-workroom", "/parent", nil)
			if !errors.Is(err, tc.sentinel) {
				t.Fatalf("expected %v, got %v", tc.sentinel, err)
			}
			if !strings.Contains(err.Error(), scriptPath) {
				t.Fatalf("expected the script's path in %q", err)
			}
		})
	}
}
