package cmd

import (
	"encoding/json"
	"errors"
	"testing"

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
