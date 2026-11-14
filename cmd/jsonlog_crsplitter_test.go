package cmd

import (
	"bytes"
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
