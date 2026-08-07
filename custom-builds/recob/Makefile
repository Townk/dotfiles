BIN     := recobd
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec
TARGET  := target/release/$(BIN)

build:
	cargo build --release --workspace
	@ls -l $(TARGET)

install: build
	install -d $(LIBEXEC)
	install -m 0755 $(TARGET) $(LIBEXEC)/$(BIN)

test:
	cargo fmt --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace

clean:
	cargo clean

.PHONY: build install test clean
