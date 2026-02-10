.PHONY: build test install lint clean

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

build:
	go build -ldflags "-X main.version=$(VERSION)" -o workroom .

test:
	go test ./...

install:
	go install -ldflags "-X main.version=$(VERSION)" .

lint:
	go vet ./...
	test -z "$$(gofmt -l .)"

clean:
	rm -f workroom
