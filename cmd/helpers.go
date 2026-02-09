package cmd

import "os"

func getCwd() (string, error) {
	return os.Getwd()
}
