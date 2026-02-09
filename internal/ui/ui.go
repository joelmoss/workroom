package ui

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/fatih/color"
)

// DisplayPath replaces the user's home directory prefix with ~.
func DisplayPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if strings.HasPrefix(path, home) {
		return "~" + path[len(home):]
	}
	return path
}

// PrintTable writes rows with optional indent to the writer.
func PrintTable(w io.Writer, rows [][]string, indent int) {
	if len(rows) == 0 {
		return
	}

	// Calculate column widths
	maxCols := 0
	for _, row := range rows {
		if len(row) > maxCols {
			maxCols = len(row)
		}
	}

	widths := make([]int, maxCols)
	for _, row := range rows {
		for i, cell := range row {
			plain := stripAnsi(cell)
			if len(plain) > widths[i] {
				widths[i] = len(plain)
			}
		}
	}

	prefix := strings.Repeat(" ", indent)
	for _, row := range rows {
		fmt.Fprint(w, prefix)
		for i, cell := range row {
			if i > 0 {
				fmt.Fprint(w, "  ")
			}
			plain := stripAnsi(cell)
			padding := widths[i] - len(plain)
			fmt.Fprint(w, cell)
			if i < len(row)-1 && padding > 0 {
				fmt.Fprint(w, strings.Repeat(" ", padding))
			}
		}
		fmt.Fprintln(w)
	}
}

// stripAnsi removes ANSI escape codes for width calculation.
func stripAnsi(s string) string {
	var result strings.Builder
	inEscape := false
	for _, r := range s {
		if r == '\033' {
			inEscape = true
			continue
		}
		if inEscape {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEscape = false
			}
			continue
		}
		result.WriteRune(r)
	}
	return result.String()
}

// Color helpers
var (
	Green  = color.New(color.FgGreen).SprintFunc()
	Red    = color.New(color.FgRed).SprintFunc()
	Yellow = color.New(color.FgYellow).SprintFunc()
	Blue   = color.New(color.FgBlue).SprintFunc()
	Bold   = color.New(color.Bold).SprintFunc()
	Dim    = color.New(color.FgHiBlack).SprintFunc()
)
