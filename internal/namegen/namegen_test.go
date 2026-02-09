package namegen

import (
	"strings"
	"testing"
)

func TestGenerate(t *testing.T) {
	t.Run("returns adjective-noun format", func(t *testing.T) {
		name := Generate()
		parts := strings.SplitN(name, "-", 2)
		if len(parts) != 2 {
			t.Fatalf("expected adjective-noun format, got %q", name)
		}
		if parts[0] == "" || parts[1] == "" {
			t.Fatalf("expected non-empty parts, got %q", name)
		}
	})

	t.Run("adjective is from the word list", func(t *testing.T) {
		name := Generate()
		adj := strings.SplitN(name, "-", 2)[0]
		found := false
		for _, a := range adjectives {
			if a == adj {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("adjective %q not in word list", adj)
		}
	})

	t.Run("noun is from the word list", func(t *testing.T) {
		name := Generate()
		noun := strings.SplitN(name, "-", 2)[1]
		found := false
		for _, n := range nouns {
			if n == noun {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("noun %q not in word list", noun)
		}
	})

	t.Run("generates different names", func(t *testing.T) {
		seen := map[string]bool{}
		for i := 0; i < 50; i++ {
			seen[Generate()] = true
		}
		if len(seen) < 2 {
			t.Fatal("expected at least 2 unique names in 50 generations")
		}
	})

	t.Run("has expected word list sizes", func(t *testing.T) {
		if len(adjectives) != 120 {
			t.Fatalf("expected 120 adjectives, got %d", len(adjectives))
		}
		if len(nouns) != 210 {
			t.Fatalf("expected 210 nouns, got %d", len(nouns))
		}
	})
}
