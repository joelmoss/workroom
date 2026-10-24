package cmd

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"maps"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

// scriptJSON is a judged script as the --json contract carries it: `text` to show, which JSON
// makes lossy for bytes that are not UTF-8, and `bytes`, the exact bytes in base64, to approve.
func scriptJSON(sc workroom.Script) map[string]any {
	return map[string]any{
		"name": sc.Name, "origin": sc.Origin, "sha256": sc.SHA256, "text": string(sc.Text),
		"bytes": base64.StdEncoding.EncodeToString(sc.Text), "trusted": sc.Trusted, "exempt": sc.Exempt,
	}
}

// localWorkJSON is local work a create would leave out (vcs.LocalWork) as the --json contract
// carries it, with `summary` to show and `behind_note`, said beside it when the local branch is
// behind ("" when it isn't).
func localWorkJSON(w vcs.LocalWork) map[string]any {
	return map[string]any{
		"branch": w.Branch, "remote": w.Remote, "ahead": w.Ahead, "uncommitted": w.Uncommitted,
		"behind": w.Behind, "summary": w.Summary(), "behind_note": w.BehindNote(),
	}
}

// schemaVersion is the version of the --json contract. Bump only on breaking changes. A new field
// or a new warning kind is additive (the app's decoders ignore unknown keys), so list's "host"
// descriptors and the HostDestroyed warning (#249) left it at 1.
const schemaVersion = 1

var (
	// jsonOutput is the root persistent --json flag.
	jsonOutput bool
	// currentCommand is set by each command's RunE so the central error writer can
	// label error envelopes with the command that produced them.
	currentCommand string
	// jsonErrorExtra carries extra fields (e.g. a partial "created" payload) to merge
	// into the next error envelope written by Execute.
	jsonErrorExtra map[string]any
)

type jsonErrorBody struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

// writeJSONSuccess emits a single success envelope on w:
// {ok:true, schema_version, cli_version, command, <payload...>}.
func writeJSONSuccess(w io.Writer, command string, payload map[string]any) error {
	obj := map[string]any{
		"ok":             true,
		"schema_version": schemaVersion,
		"cli_version":    versionStr,
		"command":        command,
	}
	maps.Copy(obj, payload)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	return enc.Encode(obj)
}

// writeJSONError emits a single error envelope on w, merging any jsonErrorExtra fields.
func writeJSONError(w io.Writer, command string, err error) {
	obj := map[string]any{
		"ok":             false,
		"schema_version": schemaVersion,
		"cli_version":    versionStr,
		"error":          jsonErrorBody{Kind: errs.Code(err), Message: err.Error()},
	}
	if command != "" {
		obj["command"] = command
	}
	// The refused script, so a GUI can show it and ask (#363).
	if untrusted := (*workroom.UntrustedScriptError)(nil); errors.As(err, &untrusted) {
		obj["script"] = scriptJSON(untrusted.Script)
	}
	// The work a create would leave out, so a GUI can ask where it starts.
	if left := (*workroom.LocalWorkError)(nil); errors.As(err, &left) {
		obj["local_work"] = localWorkJSON(left.Work)
	}
	// The start point a create question was asked about, for the answer to pass back as
	// --start-commit (ADR 0059).
	if question := (*vcs.QuestionError)(nil); errors.As(err, &question) {
		obj["start_commit"] = question.StartCommit
	}
	maps.Copy(obj, jsonErrorExtra)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(obj)
}
