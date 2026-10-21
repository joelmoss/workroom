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

// Select shows an interactive single-choice prompt and returns the index of the option chosen.
func Select(message, description string, options []string) (int, error) {
	choice := 0
	opts := make([]huh.Option[int], len(options))
	for i, o := range options {
		opts[i] = huh.NewOption(o, i)
	}
	err := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[int]().
				Title(message).
				Description(description).
				Options(opts...).
				Value(&choice),
		),
	).Run()
	return choice, err
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
