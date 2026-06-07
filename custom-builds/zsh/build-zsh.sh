#!/usr/bin/env bash
# build-zsh.sh — compile a zsh WITHOUT --enable-unicode9.
#
# Why this exists
# ---------------
# zsh's line editor (ZLE) decides how many terminal cells a character occupies.
# The stock zsh on macOS (Apple's /bin/zsh, Homebrew, and z4h's bundled binary)
# is all built with `--enable-unicode9`, which makes zsh ignore the OS and use
# its own frozen Unicode 9.0 (2016) width tables. Emoji added after that — 🧮
# (U+1F9EE, Unicode 11), 🫀 (U+1FAC0, Unicode 13), 🫠 (U+1FAE0, Unicode 14), … —
# are unknown to those tables, so zsh assigns them width 0 and ZLE renders the
# placeholder escape `<0001fac0>` instead of the glyph.
#
# macOS's libc `wcwidth()` is actually CORRECT for these (returns 2). So a zsh
# built WITHOUT --enable-unicode9 defers to the OS and renders them properly.
#
# Making it the interactive shell needs a one-time `chsh` (see README): z4h
# only searches for a "better" zsh when the *starting* shell is older than 5.8
# or can't load its modules. A healthy 5.9.x login shell is kept, and z4h
# re-execs into that same binary — so the login shell itself must be this zsh:
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

ZSH_VER="5.9.1"
ZSH_SHA256="5d20bec03f981dc4e9a09ec245e7415388ff641f79c5c5c416b5042e58d8280d"
ZSH_URL="https://downloads.sourceforge.net/project/zsh/zsh/${ZSH_VER}/zsh-${ZSH_VER}.tar.xz"

PREFIX="${ZSH_BUILD_PREFIX:-$HOME/.local/opt/zsh-nounicode9/$ZSH_VER}"
BINLINK="${ZSH_BUILD_BINLINK:-$HOME/.local/bin/zsh}"
ZSH_BIN="$PREFIX/bin/zsh"

log() { printf '[zsh-build] %s\n' "$*"; }
die() { printf '[zsh-build] error: %s\n' "$*" >&2; exit 1; }

# ${(m)#} is ZLE's own width metric; it must be 2 for a post-Unicode-9 emoji
# (U+1FAC0) on a correct, non-unicode9 build.
width_ok()   { [[ "$("$1" -fc 's=${(#):-0x1FAC0}; print -rn -- ${(m)#s}' 2>/dev/null)" == 2 ]]; }
# z4h's exec-zsh-i refuses any zsh that can't load these two modules.
modules_ok() { "$1" -fc 'zmodload -s zsh/terminfo zsh/zselect' 2>/dev/null; }

relink() {
  mkdir -p -- "$(dirname "$BINLINK")"
  ln -sfn "$ZSH_BIN" "$BINLINK"
}

# Idempotent fast path: already built, correct, and linked.
if [[ -x "$ZSH_BIN" ]] && width_ok "$ZSH_BIN" && modules_ok "$ZSH_BIN"; then
  [[ "$(readlink "$BINLINK" 2>/dev/null)" == "$ZSH_BIN" ]] || { relink; log "relinked $BINLINK"; }
  log "up-to-date: zsh $ZSH_VER (non-unicode9) at $ZSH_BIN"
  exit 0
fi

command -v clang >/dev/null 2>&1 || die "clang not found (install Xcode Command Line Tools)"

work="$(mktemp -d "${TMPDIR:-/tmp}/zsh-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"

log "downloading zsh $ZSH_VER"
curl -fsSL -o zsh.tar.xz "$ZSH_URL" || die "download failed: $ZSH_URL"
printf '%s  zsh.tar.xz\n' "$ZSH_SHA256" | shasum -a 256 -c - >/dev/null 2>&1 \
  || die "checksum mismatch for zsh.tar.xz"
tar xf zsh.tar.xz
cd "zsh-$ZSH_VER"

cflags="-O2 -Wno-implicit-int -Wno-implicit-function-declaration"
[[ "$(uname -m)" == arm64 ]] && cflags="-O2 -mcpu=native -Wno-implicit-int -Wno-implicit-function-declaration"

# zsh 5.9.1's zsh/pcre module uses PCRE2 (legacy PCRE1 was dropped). Enable it
# only when pcre2-config is present, so a machine without it still builds.
# Note: this links zsh/pcre against the pcre2 lib (e.g. Homebrew's), a runtime
# dependency that only matters when you `zmodload zsh/pcre`.
configure_args=(--prefix="$PREFIX" --enable-multibyte --with-tcsetpgrp)
if command -v pcre2-config >/dev/null 2>&1; then
  configure_args+=(--enable-pcre)
  log "pcre2-config found ($(pcre2-config --version)) -> enabling zsh/pcre"
else
  log "pcre2-config not found -> zsh/pcre skipped (brew install pcre2 to enable)"
fi

log "configuring (prefix=$PREFIX)"
CFLAGS="$cflags" ./configure "${configure_args[@]}" \
  >"$work/configure.log" 2>&1 || { tail -25 "$work/configure.log" >&2; die "configure failed"; }

# Guard against the silent-static-fallback footgun above.
grep -q '#define DYNAMIC 1' config.h \
  || { tail -25 "$work/configure.log" >&2; die "dynamic module loading was NOT enabled"; }

log "compiling (this takes ~1 min)"
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >"$work/make.log" 2>&1 \
  || { tail -25 "$work/make.log" >&2; die "make failed"; }

rm -rf "$PREFIX"
make install >"$work/install.log" 2>&1 \
  || { tail -25 "$work/install.log" >&2; die "make install failed"; }

relink

width_ok   "$ZSH_BIN" || die "post-build width self-test failed (expected width 2 for U+1FAC0)"
modules_ok "$ZSH_BIN" || die "post-build module self-test failed (zsh/terminfo + zsh/zselect)"

log "installed $("$ZSH_BIN" --version)"
log "linked $BINLINK -> $ZSH_BIN"
if [[ "$(dscl . -read "/Users/$USER" UserShell 2>/dev/null)" != *"$BINLINK"* ]]; then
  log "to use it, set it as your login shell (one-time):"
  log "  echo \"\$HOME/.local/bin/zsh\" | sudo tee -a /etc/shells && chsh -s \"\$HOME/.local/bin/zsh\""
fi
