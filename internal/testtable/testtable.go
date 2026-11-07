// Package testtable reads the tab-separated case tables that tests in several languages share, so
// each runtime's copy of a rule is checked against the same cases.
package testtable

import (
	"os"
	"strings"
	"testing"
)

// Rows reads the table at path: one row per line that is neither blank nor a # comment, split on
// tabs, each with exactly columns fields. A malformed line or a table with no rows fails the test,
// so an emptied table can't pass vacuously.
func Rows(t testing.TB, path string, columns int) [][]string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var rows [][]string
	for line := range strings.SplitSeq(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != columns {
			t.Fatalf("malformed line in %s (want %d fields): %q", path, columns, line)
		}
		rows = append(rows, fields)
	}
	if len(rows) == 0 {
		t.Fatalf("no cases in %s", path)
	}
	return rows
}
