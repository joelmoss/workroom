package cmd

import (
	"testing"

	"github.com/joelmoss/workroom/internal/channel"
)

func TestResolveUpdateChannel(t *testing.T) {
	tests := []struct {
		name         string
		baked        string
		flagSet      bool
		flagVal      string
		configVal    string
		wantCh       channel.Channel
		wantExplicit bool
		wantErr      bool
	}{
		// Nightly-baked binary: always nightly, --channel not applicable.
		{"nightly binary, no flag", "nightly", false, "", "", channel.Nightly, false, false},
		{"nightly binary rejects --channel", "nightly", true, "stable", "", "", false, true},

		// Main binary, explicit flag.
		{"main --channel stable", "", true, "stable", "", channel.Stable, true, false},
		{"main --channel pre", "", true, "pre", "", channel.Pre, true, false},
		{"main --channel nightly → separate-install error", "", true, "nightly", "", "", false, true},
		{"main --channel bogus", "", true, "bogus", "", "", false, true},

		// Main binary, no flag → config, coercing invalid/legacy to stable.
		{"main config stable", "", false, "", "stable", channel.Stable, false, false},
		{"main config pre", "", false, "", "pre", channel.Pre, false, false},
		{"main legacy config nightly coerced to stable", "", false, "", "nightly", channel.Stable, false, false},
		{"main empty config → stable", "", false, "", "", channel.Stable, false, false},
		{"main bogus config → stable", "", false, "", "bogus", channel.Stable, false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ch, explicit, err := resolveUpdateChannel(tt.baked, tt.flagSet, tt.flagVal, tt.configVal)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got ch=%q explicit=%v", ch, explicit)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if ch != tt.wantCh || explicit != tt.wantExplicit {
				t.Errorf("got (%q, %v), want (%q, %v)", ch, explicit, tt.wantCh, tt.wantExplicit)
			}
		})
	}
}
