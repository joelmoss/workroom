package ui

import (
	"github.com/charmbracelet/huh"
)

// MultiSelect shows an interactive multi-select prompt and returns the selected items.
func MultiSelect(message string, options []string) ([]string, error) {
	var selected []string
	opts := make([]huh.Option[string], len(options))
	for i, o := range options {
		opts[i] = huh.NewOption(o, o)
	}

	err := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title(message).
				Options(opts...).
				Value(&selected),
		),
	).Run()

	return selected, err
}

// Confirm shows a yes/no confirmation prompt.
func Confirm(message string) (bool, error) {
	var confirmed bool
	err := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title(message).
				Value(&confirmed),
		),
	).Run()
	return confirmed, err
}
