BIN     := pinentry-ui
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec
TARGET  := target/release/$(BIN)

build:
	cargo build --release
	@ls -l $(TARGET)

# Keychain access sticks to the binary's code-signing identity, and the
# ad-hoc signature the linker applies changes with every build — an ad-hoc
# binary would re-raise the grant dialog after each rebuild. Signing with the
# stable per-Mac `pinentry-ui-dev` identity keeps the grant across rebuilds.
# Soft on purpose: no identity means an unsigned install whose keychain read
# always fails closed into the dialog — the dormant state every fresh host
# starts in. Creating the identity is a one-time step per Mac (README,
# "Keychain integration").
CODESIGN_ID ?= pinentry-ui-dev

# libexec, not bin: gpg-agent execs this by absolute path and no human types it.
install: build
	install -d $(LIBEXEC)
	install -m 0755 $(TARGET) $(LIBEXEC)/$(BIN)
ifeq ($(shell uname -s),Darwin)
	@if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(CODESIGN_ID)"'; then \
		/usr/bin/codesign --force --sign "$(CODESIGN_ID)" "$(LIBEXEC)/$(BIN)" && \
		echo "signed with $(CODESIGN_ID)"; \
	else \
		echo "no '$(CODESIGN_ID)' identity — unsigned; the keychain lane stays dormant"; \
	fi
endif

test:
	cargo fmt --check
	cargo clippy --all-targets -- -D warnings
	cargo test

clean:
	cargo clean

.PHONY: build install test clean
