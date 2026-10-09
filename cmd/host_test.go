package cmd

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
)

func TestDecodeHostKeepsNumbersAsWritten(t *testing.T) {
	host, err := decodeHost(`{"id":9007199254740993}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := host["id"]; got != json.Number("9007199254740993") {
		t.Fatalf("id = %#v, want the number as written", got)
	}
}

func TestDecodeHostRefusesWhatIsNotOneObject(t *testing.T) {
	for _, text := range []string{`null`, `[]`, `"x"`, `{}}`, `{"a":1} {"b":2}`, ``} {
		if _, err := decodeHost(text); !errors.Is(err, errs.ErrInvalidHost) {
			t.Errorf("decodeHost(%q) err = %v, want ErrInvalidHost", text, err)
		}
	}
}

func TestHostSetWithPretendWritesNothing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := t.TempDir()
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(project)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(cfg.Path())
	hostProject, pretend = project, true
	t.Cleanup(func() { hostProject, pretend = "", false })

	if err := setHost(map[string]any{"state": "running"}); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.ReadFile(cfg.Path()); string(after) != string(before) {
		t.Fatalf("--pretend wrote the config:\n%s", after)
	}
}

// runHostCLI runs the CLI as the app does and returns its exit code and the JSON envelope it
// printed on stdout.
func runHostCLI(t *testing.T, args ...string) (int, map[string]any) {
	t.Helper()
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = write
	// cobra keeps flag values between runs.
	t.Cleanup(func() {
		jsonOutput, hostProject, hostWorkroom, pretend, currentCommand = false, "", "", false, ""
		claimFrom, claimProvisioner = "", ""
		rootCmd.SetArgs(nil)
	})
	rootCmd.SetArgs(args)
	code := Execute()
	os.Stdout = stdout
	write.Close()
	out, _ := io.ReadAll(read)
	jsonOutput, hostProject, hostWorkroom, pretend = false, "", "", false
	var envelope map[string]any
	if err := json.Unmarshal(out, &envelope); err != nil {
		t.Fatalf("not one JSON envelope: %q", out)
	}
	return code, envelope
}

func TestHostCommandsSpeakTheJSONContract(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(project)
	if err := cfg.AddWorkroom(canon, "foo", "/home/workroom/foo", "git"); err != nil {
		t.Fatal(err)
	}

	code, envelope := runHostCLI(t, "host", "set", `{"state":"running"}`, "--project", project, "--workroom", "foo", "--json")
	if code != 0 || envelope["ok"] != true || envelope["command"] != "host" || envelope["workroom"] != "foo" {
		t.Fatalf("set: exit %d, %v", code, envelope)
	}
	projects, _ := cfg.AllProjects()
	if !projects[canon].Workrooms["foo"].IsRemote() {
		t.Fatalf("the descriptor was not stored: %#v", projects[canon])
	}

	for _, refusal := range []struct {
		args []string
		code int
		kind string
	}{
		{[]string{"host", "set", "null", "--project", project, "--json"}, 2, "InvalidHostDescriptor"},
		{[]string{"host", "clear", "--project", t.TempDir(), "--json"}, 3, "ProjectNotFound"},
		{[]string{"host", "clear", "--project", project, "--workroom", "nope", "--json"}, 3, "WorkroomNotFound"},
		{[]string{"host", "set", "{}", "--project", project, "--workroom", "nope", "--json", "--pretend"}, 3, "WorkroomNotFound"},
	} {
		code, envelope := runHostCLI(t, refusal.args...)
		body, _ := envelope["error"].(map[string]any)
		if code != refusal.code || envelope["ok"] != false || body["kind"] != refusal.kind {
			t.Errorf("%v: exit %d, %v; want exit %d, %s", refusal.args, code, envelope, refusal.code, refusal.kind)
		}
	}

	code, envelope = runHostCLI(t, "host", "clear", "--project", project, "--workroom", "foo", "--json")
	projects, _ = cfg.AllProjects()
	if code != 0 || envelope["ok"] != true || projects[canon].Workrooms["foo"].IsRemote() {
		t.Fatalf("clear: exit %d, %v, %#v", code, envelope, projects[canon].Workrooms["foo"])
	}
}
