package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
)

// jsonLogWriter turns raw setup/teardown script output into newline-delimited JSON
// log events written to w (os.Stderr in --json mode). The single result/error
// envelope still goes to stdout, so stdout stays exactly one JSON object; progress
// streams on stderr for live consumers like the macOS app, which read it line by
// line as the script runs.
//
// Each complete line becomes one event: {"type":"log","phase":"setup","text":"…"}.
// It implements io.Writer and is fed from script.Run's single combined-output
// goroutine, so no locking is required.
type jsonLogWriter struct {
	w     io.Writer
	phase string
	step  string // the create step now running; tags each log event, "" when none
	buf   []byte // bytes received since the last newline, not yet emitted
	// splitCR also ends a line at a lone \r, which is how git redraws a progress counter in
	// place; \r\n still ends one line. Off for scripts, whose CRLF output must not gain events.
	splitCR bool
	lastCR  bool // the last byte consumed was a \r that ended a line, so a \n next is its pair
}

func newJSONLogWriter(w io.Writer, phase string) *jsonLogWriter {
	return &jsonLogWriter{w: w, phase: phase}
}

// writeJSONEvent emits a single NDJSON event line on w (stderr), alongside the log
// events. Used for non-log stream events such as "created" (stepEvent, createdEvent).
func writeJSONEvent(w io.Writer, obj any) {
	if data, err := encodeJSON(obj); err == nil {
		_, _ = w.Write(data)
	}
}

func (l *jsonLogWriter) Write(b []byte) (int, error) {
	if l.splitCR {
		l.writeSplittingCR(b)
		return len(b), nil
	}
	l.buf = append(l.buf, b...)
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		l.emit(string(l.buf[:i]))
		l.buf = l.buf[i+1:]
	}
	return len(b), nil
}

// writeSplittingCR is Write for splitCR: each \n, \r or \r\n ends a line.
func (l *jsonLogWriter) writeSplittingCR(b []byte) {
	for _, c := range b {
		switch {
		case c == '\n' && l.lastCR:
			l.lastCR = false
		case c == '\n' || c == '\r':
			l.emit(string(l.buf))
			l.buf = l.buf[:0]
			l.lastCR = c == '\r'
		default:
			l.lastCR = false
			l.buf = append(l.buf, c)
		}
	}
}

// Flush emits any trailing output not terminated by a newline. Call once after the
// script finishes.
func (l *jsonLogWriter) Flush() {
	if len(l.buf) > 0 {
		l.emit(string(l.buf))
		l.buf = nil
	}
}

func (l *jsonLogWriter) emit(line string) {
	rec := struct {
		Type  string `json:"type"`
		Phase string `json:"phase"`
		Step  string `json:"step,omitempty"`
		Text  string `json:"text"`
	}{Type: "log", Phase: l.phase, Step: l.step, Text: strings.TrimSuffix(line, "\r")}

	data, err := json.Marshal(rec)
	if err != nil {
		return
	}
	_, _ = l.w.Write(append(data, '\n'))
}
