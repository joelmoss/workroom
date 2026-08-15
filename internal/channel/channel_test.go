package channel

import (
	"bufio"
	"os"
	"reflect"
	"strings"
	"testing"
)

type classifyCase struct {
	tag  string
	want Channel
	ok   bool
}

// loadClassifyCases reads the tag -> channel fixture shared with
// macapp/Scripts/channel-helper_test.sh (testdata/channel_cases.tsv), so a newly discovered
// classification case is added once instead of independently to two hand-maintained lists —
// which had already silently drifted apart (see the dangling-hyphen and -nightly-suffix cases).
func loadClassifyCases(t *testing.T) []classifyCase {
	t.Helper()
	f, err := os.Open("testdata/channel_cases.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	var cases []classifyCase
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		tag, want, found := strings.Cut(line, "\t")
		if !found {
			t.Fatalf("malformed fixture line (no tab): %q", line)
		}
		if want == "EXCLUDED" {
			cases = append(cases, classifyCase{tag, "", false})
		} else {
			cases = append(cases, classifyCase{tag, Channel(want), true})
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return cases
}

func TestClassify(t *testing.T) {
	for _, tt := range loadClassifyCases(t) {
		t.Run(tt.tag, func(t *testing.T) {
			got, ok := Classify(tt.tag)
			if got != tt.want || ok != tt.ok {
				t.Errorf("Classify(%q) = (%q, %v), want (%q, %v)", tt.tag, got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestFloorSet(t *testing.T) {
	tests := []struct {
		ch   Channel
		want []Channel
	}{
		{Stable, []Channel{Stable}},
		{Pre, []Channel{Stable, Pre}},
		{Nightly, []Channel{Stable, Pre, Nightly}},
		{Channel("bogus"), nil},
	}
	for _, tt := range tests {
		t.Run(string(tt.ch), func(t *testing.T) {
			if got := FloorSet(tt.ch); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("FloorSet(%q) = %v, want %v", tt.ch, got, tt.want)
			}
		})
	}
}

func TestAccepts(t *testing.T) {
	tests := []struct {
		user, tagCh Channel
		want        bool
	}{
		{Stable, Stable, true},
		{Stable, Pre, false}, // stable never sees prereleases
		{Stable, Nightly, false},
		{Pre, Stable, true}, // floor: pre gets stable too
		{Pre, Pre, true},
		{Pre, Nightly, false},
		{Nightly, Stable, true}, // floor: nightly gets everything
		{Nightly, Pre, true},
		{Nightly, Nightly, true},
		{Channel("bogus"), Stable, false},
	}
	for _, tt := range tests {
		t.Run(string(tt.user)+"/"+string(tt.tagCh), func(t *testing.T) {
			if got := Accepts(tt.user, tt.tagCh); got != tt.want {
				t.Errorf("Accepts(%q, %q) = %v, want %v", tt.user, tt.tagCh, got, tt.want)
			}
		})
	}
}

func TestParse(t *testing.T) {
	tests := []struct {
		in   string
		want Channel
		ok   bool
	}{
		{"stable", Stable, true},
		{"pre", Pre, true},
		{"nightly", Nightly, true},
		{"", "", false},
		{"Stable", "", false}, // case-sensitive
		{"beta", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.in, func(t *testing.T) {
			got, ok := Parse(tt.in)
			if got != tt.want || ok != tt.ok {
				t.Errorf("Parse(%q) = (%q, %v), want (%q, %v)", tt.in, got, ok, tt.want, tt.ok)
			}
		})
	}
}
