BIN     := pty-frame
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec

build:
	go build -o $(BIN) .

install: build
	install -d $(LIBEXEC)
	install -m 0755 $(BIN) $(LIBEXEC)/$(BIN)

test:
	go test ./...

clean:
	rm -f $(BIN)

.PHONY: build install test clean
