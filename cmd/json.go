package cmd

import (
	"encoding/json"
	"io"
	"maps"

	"github.com/joelmoss/workroom/internal/errs"
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
	maps.Copy(obj, jsonErrorExtra)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(obj)
}
