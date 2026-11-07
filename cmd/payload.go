package cmd

import (
	"encoding/base64"

	"github.com/joelmoss/workroom/internal/workroom"
)

// The --json contract's payloads (ADR 0013), one type per command shape, kept together so the
// whole contract reads in one place. writeJSONSuccess merges a payload's fields into the envelope
// and writes the top level in key order, so a top-level field's place here doesn't matter. A
// nested object (script, local_work, created) and an NDJSON event are written as declared, so
// their fields are in key order, as the goldens in testdata/contracts have them. omitempty marks
// only a key the command leaves out when it is unset.

// versionPayload is `version`'s.
type versionPayload struct {
	Channel             string `json:"channel"`
	ConfigSchemaVersion int    `json:"config_schema_version"`
	Version             string `json:"version"`
}

// addProjectPayload is `add-project`'s. WouldCreate is set only under --pretend, false included.
type addProjectPayload struct {
	Path        string `json:"path"`
	VCS         string `json:"vcs"`
	WouldCreate *bool  `json:"would_create,omitempty"`
}

// basePayload is `base set` and `base clear`'s: the base branch ("" when cleared) of the project,
// or with --global the default for every project.
type basePayload struct {
	BaseBranch string `json:"base_branch"`
	Global     bool   `json:"global,omitempty"`
	Project    string `json:"project,omitempty"`
}

// hostPayload is `host set` and `host clear`'s. Workroom is "" for the project's own descriptor.
type hostPayload struct {
	Project  string `json:"project"`
	Workroom string `json:"workroom"`
}

// claimPayload is `claim-provisioned`'s: how many entries moved.
type claimPayload struct {
	Moved int `json:"moved"`
}

// createPayload is a created workroom: `create`'s payload, and the "created" object of a create
// whose setup failed after the workroom was made.
type createPayload struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Project string `json:"project"`
	VCS     string `json:"vcs"`
	Warning string `json:"warning,omitempty"`
}

// createdEvent is the NDJSON "created" event a create streams before its setup script runs.
// Warning is there even when "".
type createdEvent struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Project string `json:"project"`
	Setup   bool   `json:"setup"`
	Type    string `json:"type"`
	VCS     string `json:"vcs"`
	Warning string `json:"warning"`
}

// stepEvent is the NDJSON "step" event that drives the app's creation checklist.
type stepEvent struct {
	Detail string `json:"detail,omitempty"`
	ID     string `json:"id"`
	State  string `json:"state"`
	Type   string `json:"type"`
}

// deletePayload is `delete`'s.
type deletePayload struct {
	Name string `json:"name"`
}

// deleteProjectPayload is `delete-project`'s without --from-disk.
type deleteProjectPayload struct {
	Path          string `json:"path"`
	WithWorkrooms bool   `json:"with_workrooms"`
}

// deleteProjectFromDiskPayload is `delete-project --from-disk`'s: the paths the app moves to the
// Trash.
type deleteProjectFromDiskPayload struct {
	FromDisk   bool     `json:"from_disk"`
	Path       string   `json:"path"`
	TrashPaths []string `json:"trash_paths"`
}

// includeArchivePayload is `include-archive`'s. Its lists are [] when empty, never null.
type includeArchivePayload struct {
	Bytes    int64    `json:"bytes"`
	Count    int      `json:"count"`
	Paths    []string `json:"paths"`
	Skipped  []string `json:"skipped"`
	Warnings []string `json:"warnings"`
}

// listPayload is `list`'s. BaseBranch is the global default, left out when unset.
type listPayload struct {
	BaseBranch   string                 `json:"base_branch,omitempty"`
	ConfigPath   string                 `json:"config_path"`
	Projects     []workroom.ProjectInfo `json:"projects"`
	WorkroomsDir string                 `json:"workrooms_dir"`
}

// trustPayload is `trust`'s: the scripts judged, with what was approved.
type trustPayload struct {
	Scripts []scriptPayload `json:"scripts"`
}

// trustStatusPayload is `trust status`'s. LocalWork is what a create from that start leaves out,
// for a remote create to warn about, and Start the commit --base names.
type trustStatusPayload struct {
	LocalWork *localWorkPayload `json:"local_work,omitempty"`
	Scripts   []scriptPayload   `json:"scripts"`
	Start     string            `json:"start,omitempty"`
	Trusted   bool              `json:"trusted"`
}

// untrustPayload is `untrust`'s.
type untrustPayload struct {
	Project string `json:"project"`
}

// scriptPayload is a judged script: Text to show, which JSON makes lossy for bytes that are not
// UTF-8, and Bytes, the exact bytes in base64, to approve.
type scriptPayload struct {
	Bytes   string `json:"bytes"`
	Exempt  bool   `json:"exempt"`
	File    string `json:"file"`
	Name    string `json:"name"`
	Origin  string `json:"origin"`
	SHA256  string `json:"sha256"`
	Text    string `json:"text"`
	Trusted bool   `json:"trusted"`
}

func newScriptPayload(sc workroom.Script) scriptPayload {
	return scriptPayload{
		Bytes: base64.StdEncoding.EncodeToString(sc.Text), Exempt: sc.Exempt, File: sc.File, Name: sc.Name,
		Origin: sc.Origin, SHA256: sc.SHA256, Text: string(sc.Text), Trusted: sc.Trusted,
	}
}

func newScriptPayloads(scripts []workroom.Script) []scriptPayload {
	out := make([]scriptPayload, 0, len(scripts))
	for _, sc := range scripts {
		out = append(out, newScriptPayload(sc))
	}
	return out
}

// localWorkPayload is local work a create would leave out, with Summary to show and BehindNote,
// said beside it when the local branch is behind ("" when it isn't).
type localWorkPayload struct {
	Ahead       int    `json:"ahead"`
	Behind      int    `json:"behind"`
	BehindNote  string `json:"behind_note"`
	Branch      string `json:"branch"`
	Remote      string `json:"remote"`
	Summary     string `json:"summary"`
	Uncommitted bool   `json:"uncommitted"`
}

func newLocalWorkPayload(w workroom.LocalWork) *localWorkPayload {
	return &localWorkPayload{
		Ahead: w.Ahead, Behind: w.Behind, BehindNote: w.BehindNote(), Branch: w.Branch, Remote: w.Remote,
		Summary: w.Summary(), Uncommitted: w.Uncommitted,
	}
}

// errorEnvelope is the envelope of a failed command, in key order. Command is "" when the command
// never started (a flag error); Created, Script, LocalWork and StartCommit are set by the errors
// that carry them.
type errorEnvelope struct {
	CLIVersion    string            `json:"cli_version"`
	Command       string            `json:"command,omitempty"`
	Created       *createPayload    `json:"created,omitempty"`
	Error         jsonErrorBody     `json:"error"`
	LocalWork     *localWorkPayload `json:"local_work,omitempty"`
	OK            bool              `json:"ok"`
	SchemaVersion int               `json:"schema_version"`
	Script        *scriptPayload    `json:"script,omitempty"`
	StartCommit   string            `json:"start_commit,omitempty"`
}

type jsonErrorBody struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}
