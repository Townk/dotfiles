BIN     := tm-timeline
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec

build:
	go build -o $(BIN) .

install: build
	install -d $(LIBEXEC)
	install -m 0755 $(BIN) $(LIBEXEC)/$(BIN)

test:
	go vet ./...

.PHONY: build install test
