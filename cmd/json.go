package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/workroom"
)

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
	// jsonErrorCreated is the workroom a failed create made anyway, for the next error envelope
	// Execute writes to report as "created".
	jsonErrorCreated *createPayload
)

// writeJSONSuccess emits a single success envelope on w:
// {ok:true, schema_version, cli_version, command, <payload's fields...>}, every key in order.
func writeJSONSuccess(w io.Writer, command string, payload any) error {
	data, err := encodeJSON(payload)
	if err != nil {
		return err
	}
	// The payload's fields, each as encoded, so nested objects keep their declared order.
	fields := map[string]json.RawMessage{}
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	obj := map[string]any{
		"ok":             true,
		"schema_version": schemaVersion,
		"cli_version":    versionStr,
		"command":        command,
	}
	for key, value := range fields {
		obj[key] = value
	}
	data, err = encodeJSON(obj)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// writeJSONError emits a single error envelope on w, with what the error carries and any
// jsonErrorCreated workroom.
func writeJSONError(w io.Writer, command string, err error) {
	env := errorEnvelope{
		CLIVersion:    versionStr,
		Command:       command,
		Created:       jsonErrorCreated,
		Error:         jsonErrorBody{Kind: errs.Code(err), Message: err.Error()},
		SchemaVersion: schemaVersion,
	}
	// The refused script, so a GUI can show it and ask (#363).
	if untrusted := (*workroom.UntrustedScriptError)(nil); errors.As(err, &untrusted) {
		script := newScriptPayload(untrusted.Script)
		env.Script = &script
	}
	// The work a create would leave out, so a GUI can ask where it starts.
	if left := (*workroom.LocalWorkError)(nil); errors.As(err, &left) {
		env.LocalWork = newLocalWorkPayload(left.Work)
	}
	// The start point a create question was asked about, for the answer to pass back as
	// --start-commit (ADR 0059).
	if question := (*workroom.QuestionError)(nil); errors.As(err, &question) {
		env.StartCommit = question.StartCommit
	}
	if data, err := encodeJSON(env); err == nil {
		_, _ = w.Write(data)
	}
}

// encodeJSON is v as one line of JSON, newline-terminated, with <, > and & left as they are.
func encodeJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
