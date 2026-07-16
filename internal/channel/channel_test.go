package channel

import (
	"reflect"
	"testing"
)

func TestClassify(t *testing.T) {
	tests := []struct {
		tag  string
		want Channel
		ok   bool
	}{
		{"v1.3.0", Stable, true},
		{"v2.0.0", Stable, true},
		{"1.3.0", Stable, true}, // v prefix optional
		{"v2.0.0-beta.21", Pre, true},
		{"v2.0.0-beta.1", Pre, true},
		{"v1.4.0-rc1", Pre, true},
		{"v1.4.0-rc.1", Pre, true},
		{"v1.4.0-alpha", Pre, true},
		{"v2.0.0-nightly.941", Pre, true}, // a -nightly *suffix* is still a prerelease tag; the nightly channel uses the fixed "nightly" tag, not a suffix
		{"nightly", Nightly, true},
		{"appcast", "", false}, // feed host, excluded
		{"", "", false},
		{"garbage", "", false},
		{"v1.2", "", false},   // not three fields
		{"v1.2.x", "", false}, // non-numeric
		{"v1.2.3+build.5", Stable, true},
		{"v2.0.0-beta.1+exp", Pre, true},
	}
	for _, tt := range tests {
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
