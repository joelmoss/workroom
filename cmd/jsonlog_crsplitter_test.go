package cmd

import (
	"bytes"
	"encoding/json"
	"testing"
)

// Value: protects=git progress redrawn with \r becomes separate log events, CRLF stays one line end;
// fails_when=a lone \r is passed through, or a \r\n split across Writes yields a blank line;
// why_new=only an end-to-end clone covers it and git's CR chunking there is nondeterministic; seam=none;
// no_claim=does not cover jsonLogWriter itself
func TestCRSplitter(t *testing.T) {
	cases := []struct {
		name   string
		writes []string
		want   string
	}{
		{"lone CR becomes newline", []string{"a: 1%\ra: 2%\r"}, "a: 1%\na: 2%\n"},
		{"CRLF stays one line end", []string{"a\r\nb\r\n"}, "a\nb\n"},
		{"CRLF split across writes", []string{"a\r", "\nb"}, "a\nb"},
		{"CR then text across writes", []string{"a\r", "b"}, "a\nb"},
		{"LF alone untouched", []string{"a\nb\n"}, "a\nb\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var out bytes.Buffer
			s := &crSplitter{w: &out}
			for _, w := range c.writes {
				n, err := s.Write([]byte(w))
				if err != nil || n != len(w) {
					t.Fatalf("Write(%q) = %d, %v; want %d, nil", w, n, err, len(w))
				}
			}
			if out.String() != c.want {
				t.Fatalf("got %q, want %q", out.String(), c.want)
			}
		})
	}
}

// Value: protects=output that never sends a newline can't grow the CLI's line buffer without limit,
// and none of it is lost; fails_when=jsonLogWriter only emits at newline; why_new=no test feeds an
// overlong line; seam=none; no_claim=does not check the app's own cap
func TestJSONLogWriterSplitsAnOverlongLine(t *testing.T) {
	var out bytes.Buffer
	w := newJSONLogWriter(&out, "clone")
	chunk := bytes.Repeat([]byte("x"), 64<<10)
	for i := 0; i < 20; i++ { // 1.25 MiB with no newline
		if _, err := w.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	if len(w.buf) > maxLogLine {
		t.Fatalf("buffer holds %d bytes, want at most %d", len(w.buf), maxLogLine)
	}
	w.Flush()
	total := 0
	for _, line := range bytes.Split(bytes.TrimSuffix(out.Bytes(), []byte("\n")), []byte("\n")) {
		var ev struct{ Text string }
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("event %q: %v", line[:min(len(line), 60)], err)
		}
		total += len(ev.Text)
	}
	if total != 20*len(chunk) {
		t.Fatalf("events carry %d bytes, want all %d", total, 20*len(chunk))
	}
}

// Value: protects=splitting an endless line never cuts a multi-byte character in two; fails_when=the
// split is by byte alone; why_new=the overlong test uses ASCII; seam=none; no_claim=none beyond protects
func TestJSONLogWriterSplitsOnACharacterBoundary(t *testing.T) {
	var out bytes.Buffer
	w := newJSONLogWriter(&out, "clone")
	text := bytes.Repeat([]byte("é"), maxLogLine) // two bytes each, so a byte cut lands mid-character
	if _, err := w.Write(text); err != nil {
		t.Fatal(err)
	}
	w.Flush()
	got := ""
	for _, line := range bytes.Split(bytes.TrimSuffix(out.Bytes(), []byte("\n")), []byte("\n")) {
		var ev struct{ Text string }
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatal(err)
		}
		got += ev.Text
	}
	if got != string(text) {
		t.Fatalf("characters were split: %d bytes back, want %d", len(got), len(text))
	}
}
