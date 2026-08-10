BIN     := pinentry-ui
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec
TARGET  := target/release/$(BIN)

build:
	cargo build --release
	@ls -l $(TARGET)

# libexec, not bin: gpg-agent execs this by absolute path and no human types it.
install: build
	install -d $(LIBEXEC)
	install -m 0755 $(TARGET) $(LIBEXEC)/$(BIN)

test:
	cargo fmt --check
	cargo clippy --all-targets -- -D warnings
	cargo test

clean:
	cargo clean

.PHONY: build install test clean
