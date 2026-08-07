BIN     := recobd
CLIENT  := system-clip
BRIDGE  := system-bridge
PREFIX  ?= $(HOME)/.local
LIBEXEC := $(PREFIX)/libexec
BINDIR  := $(PREFIX)/bin
TARGET  := target/release/$(BIN)
CTARGET := target/release/$(CLIENT)
BTARGET := target/release/$(BRIDGE)

build:
	cargo build --release --workspace
	@ls -l $(TARGET) $(CTARGET) $(BTARGET)

# The daemon goes to libexec (nothing calls it by hand); the client goes to
# bin, where the pbcopy/pbpaste trampolines exec it; the generic invoker goes
# to libexec too — it is plumbing the clipbridge:: zsh wrapper execs, not a
# command a human types, and system-clip stays the only PATH-visible RECOB
# binary. All are installed together: a client newer than its daemon is the
# skew §7 exists to diagnose, and there is no reason to create it here.
install: build
	install -d $(LIBEXEC) $(BINDIR)
	install -m 0755 $(TARGET) $(LIBEXEC)/$(BIN)
	install -m 0755 $(CTARGET) $(BINDIR)/$(CLIENT)
	install -m 0755 $(BTARGET) $(LIBEXEC)/$(BRIDGE)

test:
	cargo fmt --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace

clean:
	cargo clean

.PHONY: build install test clean
