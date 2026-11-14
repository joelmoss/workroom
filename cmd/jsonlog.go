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
	l.buf = append(l.buf, b...)
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		l.emit(string(l.buf[:i]))
		l.buf = l.buf[i+1:]
	}
	// Output that never sends a newline (a hostile git server's endless sideband text) is emitted in
	// maxLogLine pieces rather than held: the buffer stays bounded and nothing is lost.
	for len(l.buf) >= maxLogLine {
		l.emit(string(l.buf[:maxLogLine]))
		l.buf = l.buf[maxLogLine:]
	}
	return len(b), nil
}

// maxLogLine is the most of one line jsonLogWriter holds before emitting it as an event of its own.
const maxLogLine = 1 << 20

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

// crSplitter turns each lone \r into \n before passing output on, so a writer that splits lines on
// \n also ends one where git redraws a progress counter in place. A \r\n stays one line end. Only
// clone output goes through it: a script's CRLF output must not gain events.
type crSplitter struct {
	w      io.Writer
	lastCR bool // the last byte was a \r, so a \n next is its pair
}

func (c *crSplitter) Write(b []byte) (int, error) {
	out := make([]byte, 0, len(b))
	for _, ch := range b {
		switch {
		case ch == '\n' && c.lastCR:
			c.lastCR = false
		case ch == '\r':
			out = append(out, '\n')
			c.lastCR = true
		default:
			out = append(out, ch)
			c.lastCR = false
		}
	}
	if _, err := c.w.Write(out); err != nil {
		return 0, err
	}
	return len(b), nil
}
