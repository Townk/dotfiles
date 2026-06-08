#!/usr/bin/env bash
# build-zsh.sh — compile zsh from a git clone WITHOUT --enable-unicode9.
#
# Why this exists
# ---------------
# zsh's line editor (ZLE) decides how many terminal cells a character occupies.
# The stock zsh on macOS (Apple's /bin/zsh, Homebrew, and z4h's bundled binary)
# is all built with `--enable-unicode9`, which makes zsh ignore the OS and use
# its own frozen Unicode 9.0 (2016) width tables. Emoji added after that — 🧮
# (U+1F9EE, Unicode 11), 🫀 (U+1FAC0, Unicode 13), 🫠 (U+1FAE0, Unicode 14), … —
# are unknown to those tables, so zsh assigns them width 0 and ZLE renders the
# placeholder escape `<0001fac0>` instead of the glyph. (That table is frozen
# even on zsh master, so a newer release / `brew --HEAD` would not fix it.)
#
# macOS's libc `wcwidth()` is actually CORRECT for these (returns 2). So a zsh
# built WITHOUT --enable-unicode9 defers to the OS and renders them properly.
#
# Source of truth
# ---------------
# A shallow clone of the upstream zsh repo, kept under ./build/zsh so updates
# are a cheap fetch (run with ZSH_UPDATE=1, or `git pull` by hand). Building
# from git rather than a release tarball means:
#   * we regenerate `configure` with autoconf via Util/preconfig; and
#   * we track the ZSH_REF branch — default `master` (development code), with
#     git as the trust anchor instead of a pinned tarball checksum.
# Pin ZSH_REF to a release tag (e.g. ZSH_REF=zsh-5.9.1) for a stable point.
#
# This also makes it the login shell (ensure_login_shell, below): z4h only
# searches for a "better" zsh when the *starting* shell is older than 5.8 or
# can't load its modules. A healthy 5.x login shell is kept, and z4h re-execs
# into that same binary — so the login shell itself must be this zsh. The chsh
# + /etc/shells edit prompt for a password, so it runs only with a tty (e.g.
# interactive `chezmoi apply` during bootstrap); otherwise it prints:
#   echo "$HOME/.local/bin/zsh" | sudo tee -a /etc/shells
#   chsh -s "$HOME/.local/bin/zsh"
#
# Build recipe gotchas (modern toolchain, clang >= 16 / macOS):
#   * -Wno-implicit-int -Wno-implicit-function-declaration: zsh's configure
#     probes use pre-C99 code that clang now treats as hard errors. Left
#     unhandled, the "environ in shared libraries" probe fails and configure
#     SILENTLY disables dynamic module loading (DYNAMIC), dropping modules z4h
#     requires (zsh/zselect, zsh/system) to link=no.
#   * --with-tcsetpgrp: the tcsetpgrp() *runtime* probe needs a controlling
#     tty, which a chezmoi hook / CI shell does not have. macOS supports it, so
#     assert it rather than letting the probe abort configure.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
BUILD_ROOT="${ZSH_BUILD_ROOT:-$SCRIPT_DIR/build}"
REPO="$BUILD_ROOT/zsh"
ZSH_URL="${ZSH_URL:-https://github.com/zsh-users/zsh.git}"
ZSH_REF="${ZSH_REF:-master}"

PREFIX="${ZSH_BUILD_PREFIX:-$HOME/.local/opt/zsh}"
BINLINK="${ZSH_BUILD_BINLINK:-$HOME/.local/bin/zsh}"
ZSH_BIN="$PREFIX/bin/zsh"
STAMP="$PREFIX/.source-commit"

log() { printf '[zsh-build] %s\n' "$*"; }
die() { printf '[zsh-build] error: %s\n' "$*" >&2; exit 1; }

# ${(m)#} is ZLE's own width metric; it must be 2 for a post-Unicode-9 emoji
# (U+1FAC0) on a correct, non-unicode9 build.
width_ok()   { [[ "$("$1" -fc 's=${(#):-0x1FAC0}; print -rn -- ${(m)#s}' 2>/dev/null)" == 2 ]]; }
# z4h's exec-zsh-i refuses any zsh that can't load these two modules.
modules_ok() { "$1" -fc 'zmodload -s zsh/terminfo zsh/zselect' 2>/dev/null; }
relink()     { mkdir -p -- "$(dirname "$BINLINK")"; ln -sfn "$ZSH_BIN" "$BINLINK"; }
repo_commit() { git -C "$REPO" rev-parse --short HEAD 2>/dev/null; }

# Make this zsh the login shell (idempotent). z4h won't switch on its own for a
# healthy 5.x shell — it re-execs the *starting* binary — so the login shell
# itself must be this zsh. Registering it needs /etc/shells (sudo) + chsh, both
# of which prompt for a password; only attempt with a tty (e.g. interactive
# `chezmoi apply` during bootstrap), otherwise print the one-liner.
ensure_login_shell() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  local current
  current="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $NF}')"
  [[ "$current" == "$BINLINK" ]] && return 0

  if [[ ! -t 0 && ! -t 1 ]]; then
    log "login shell is $current; to switch (run once, interactive):"
    log "  echo \"$BINLINK\" | sudo tee -a /etc/shells && chsh -s \"$BINLINK\""
    return 0
  fi

  if ! grep -qxF -- "$BINLINK" /etc/shells 2>/dev/null; then
    log "registering $BINLINK in /etc/shells (sudo)"
    printf '%s\n' "$BINLINK" | sudo tee -a /etc/shells >/dev/null \
      || { log "could not update /etc/shells; set manually: chsh -s $BINLINK"; return 0; }
  fi
  log "setting login shell -> $BINLINK (chsh)"
  chsh -s "$BINLINK" || log "chsh failed; set manually: chsh -s $BINLINK"
}

# 1. Fast path: healthy install built from the clone's current commit, and not
#    explicitly updating. rev-parse is local/offline; we only hit the network
#    to clone or when ZSH_UPDATE is set.
if [[ -z "${ZSH_UPDATE:-}" && -x "$ZSH_BIN" && -d "$REPO/.git" \
      && "$(cat "$STAMP" 2>/dev/null)" == "$(repo_commit)" ]] \
   && width_ok "$ZSH_BIN" && modules_ok "$ZSH_BIN"; then
  [[ "$(readlink "$BINLINK" 2>/dev/null)" == "$ZSH_BIN" ]] || { relink; log "relinked $BINLINK"; }
  ensure_login_shell
  log "up-to-date: zsh @ $(repo_commit) (non-unicode9) at $ZSH_BIN"
  exit 0
fi

# 2. Ensure the shallow clone exists; update it when ZSH_UPDATE is set.
command -v git >/dev/null 2>&1 || die "git not found on PATH"
if [[ -d "$REPO/.git" ]]; then
  if [[ -n "${ZSH_UPDATE:-}" ]]; then
    log "updating clone to latest $ZSH_REF"
    # Shallow clones choke on `git pull` (it backfills history); fetch + reset
    # is the safe pattern.
    git -C "$REPO" fetch --depth 1 --quiet origin "$ZSH_REF"
    git -C "$REPO" reset --hard --quiet FETCH_HEAD
  fi
else
  log "shallow-cloning zsh ($ZSH_REF) into $REPO"
  mkdir -p -- "$BUILD_ROOT"
  git clone --depth 1 --branch "$ZSH_REF" --quiet "$ZSH_URL" "$REPO" || die "git clone failed"
fi
commit="$(repo_commit)"

# 3. Toolchain. Building from git needs autoconf (Util/preconfig regenerates
#    ./configure, which a release tarball would already ship). autoconf has no
#    mise equivalent, so the Brewfile is its source of truth. But this hook can
#    run BEFORE the package sync that installs it: `system-update` does
#    `chezmoi apply` (which fires this builder) before `system-package sync`,
#    and on an already-bootstrapped machine run_once_after_10 won't re-run to
#    install it first. So provision the build-only dep on demand here rather
#    than failing — brew is guaranteed present on the macOS profiles we target.
command -v clang >/dev/null 2>&1 || die "clang not found (install Xcode Command Line Tools)"
if ! command -v autoconf >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 \
    || die "autoconf not found and brew unavailable — run 'system-package-brew' (or 'brew install autoconf')"
  log "autoconf missing; installing via brew (declared in Brewfile)"
  brew install autoconf >"$BUILD_ROOT/autoconf-install.log" 2>&1 \
    || { tail -25 "$BUILD_ROOT/autoconf-install.log" >&2; die "autoconf install failed"; }
fi

cd "$REPO"

# -O3 + tune for the building host. On AArch64, -mcpu=native selects this Mac's
# core (M-series) for both ISA extensions and scheduling; that's the correct
# single knob (see README). The binary is built per-machine, so "native" is safe.
cflags="-O3 -Wno-implicit-int -Wno-implicit-function-declaration"
[[ "$(uname -m)" == arm64 ]] && cflags="-O3 -mcpu=native -Wno-implicit-int -Wno-implicit-function-declaration"

log "regenerating configure (autoconf)"
./Util/preconfig >"$BUILD_ROOT/preconfig.log" 2>&1 \
  || { tail -25 "$BUILD_ROOT/preconfig.log" >&2; die "preconfig failed"; }

# zsh master's zsh/pcre module uses PCRE2 (legacy PCRE1 was dropped). Enable it
# only when pcre2-config is present, so a machine without it still builds. This
# links zsh/pcre against the pcre2 lib (e.g. Homebrew's), a runtime dependency
# that only matters when you `zmodload zsh/pcre`.
configure_args=(--prefix="$PREFIX" --enable-multibyte --with-tcsetpgrp)
if command -v pcre2-config >/dev/null 2>&1; then
  configure_args+=(--enable-pcre)
  log "pcre2-config found ($(pcre2-config --version)) -> enabling zsh/pcre"
else
  log "pcre2-config not found -> zsh/pcre skipped (brew install pcre2 to enable)"
fi

log "configuring (prefix=$PREFIX)"
CFLAGS="$cflags" ./configure "${configure_args[@]}" \
  >"$BUILD_ROOT/configure.log" 2>&1 || { tail -25 "$BUILD_ROOT/configure.log" >&2; die "configure failed"; }

# Guard against the silent-static-fallback footgun above.
grep -q '#define DYNAMIC 1' config.h \
  || { tail -25 "$BUILD_ROOT/configure.log" >&2; die "dynamic module loading was NOT enabled"; }

log "compiling (this takes ~1 min)"
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >"$BUILD_ROOT/make.log" 2>&1 \
  || { tail -25 "$BUILD_ROOT/make.log" >&2; die "make failed"; }

# Install only binary + modules + shell functions. Docs need yodl (not a build
# dep) and the system already ships zsh man pages.
rm -rf "$PREFIX"
make install.bin install.modules install.fns >"$BUILD_ROOT/install.log" 2>&1 \
  || { tail -25 "$BUILD_ROOT/install.log" >&2; die "make install failed"; }
printf '%s\n' "$commit" > "$STAMP"

relink

width_ok   "$ZSH_BIN" || die "post-build width self-test failed (expected width 2 for U+1FAC0)"
modules_ok "$ZSH_BIN" || die "post-build module self-test failed (zsh/terminfo + zsh/zselect)"

log "installed $("$ZSH_BIN" --version) @ $commit"
log "linked $BINLINK -> $ZSH_BIN"
ensure_login_shell
