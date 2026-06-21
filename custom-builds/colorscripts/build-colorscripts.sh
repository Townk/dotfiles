#!/usr/bin/env bash
# build-colorscripts.sh — install shell-color-scripts into ~/.local/opt
# WITHOUT sudo, patching its hardcoded /opt data dir to the user install.
#
# Why this exists
# ---------------
# The NeoVim dashboard (lua/plugins/core.lua) renders a colorscript on
# startup via `colorscript -e square`. shell-color-scripts (Derek Taylor,
# GitLab) ships a Makefile that does:
#
#   cp colorscript.sh /usr/local/bin/colorscript
#   cp -rf colorscripts/* /opt/shell-color-scripts/colorscripts
#
# Two problems with that on this setup:
#   * /opt and /usr/local/bin are sudo-owned, and on Apple Silicon
#     /usr/local/bin is the Intel-Homebrew path — it's NOT on $PATH (native
#     Homebrew lives in /opt/homebrew). So `colorscript` ends up installed
#     but uncallable, producing `zsh:1: command not found: colorscript` from
#     the nvim-spawned shell.
#   * The CLI hardcodes DIR_COLORSCRIPTS="/opt/shell-color-scripts/colorscripts"
#     (line 8), so even a PATH symlink to the binary would still point at the
#     sudo-owned data dir.
#
# mise can't manage this one: its aqua/github/gitlab backends all download
# *release assets attached to tagged releases*, and this project has no tags
# and no releases — it's a shell script + a data directory, distributed by
# `make install`. So we clone it ourselves and do the equivalent of
# `make install` into a user-owned prefix, then patch the one static path.
#
# Source of truth
# ---------------
# A shallow clone of the upstream GitLab repo, kept under ./build so updates
# are a cheap fetch (run with COLORSCRIPTS_UPDATE=1). There are no release
# tags, so we track `master` with git as the trust anchor instead of a pinned
# checksum — same model as custom-builds/zsh.
#
# Install layout (~/.local/opt/colorscripts):
#   bin/colorscript            the CLI (patched, executable)
#   share/colorscripts/        the colorscript data scripts
# And a symlink ~/.local/bin/colorscript -> the installed bin, which IS on
# $PATH — so the only thing dropped into ~/.local/bin is a link (the real
# script content lives in this clone + the prefix, both user-owned).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
BUILD_ROOT="${COLORSCRIPTS_BUILD_ROOT:-$SCRIPT_DIR/build}"
REPO="$BUILD_ROOT/shell-color-scripts"
URL="${COLORSCRIPTS_URL:-https://gitlab.com/dwt1/shell-color-scripts.git}"
REF="${COLORSCRIPTS_REF:-master}"

PREFIX="${COLORSCRIPTS_PREFIX:-$HOME/.local/opt/colorscripts}"
BINLINK="${COLORSCRIPTS_BINLINK:-$HOME/.local/bin/colorscript}"
INSTALLED_BIN="$PREFIX/bin/colorscript"
INSTALLED_DATA="$PREFIX/share/colorscripts"
STAMP="$PREFIX/.source-commit"

STATIC_PATH='DIR_COLORSCRIPTS="/opt/shell-color-scripts/colorscripts"'
PATCHED_PATH='DIR_COLORSCRIPTS="$HOME/.local/opt/colorscripts/share/colorscripts"'

log() { printf '[colorscripts-build] %s\n' "$*"; }
die() { printf '[colorscripts-build] error: %s\n' "$*" >&2; exit 1; }
repo_commit() { git -C "$REPO" rev-parse --short HEAD 2>/dev/null; }
relink() { mkdir -p -- "$(dirname "$BINLINK")"; ln -sfn "$INSTALLED_BIN" "$BINLINK"; }

# 1. Fast path: installed bin + data exist, clone present, stamp matches the
#    clone's current commit, and we're not explicitly updating. rev-parse is
#    local/offline; we only hit the network to clone or on COLORSCRIPTS_UPDATE.
if [[ -z "${COLORSCRIPTS_UPDATE:-}" && -x "$INSTALLED_BIN" && -d "$INSTALLED_DATA" \
      && -d "$REPO/.git" && "$(cat "$STAMP" 2>/dev/null)" == "$(repo_commit)" ]]; then
  [[ "$(readlink "$BINLINK" 2>/dev/null)" == "$INSTALLED_BIN" ]] || { relink; log "relinked $BINLINK"; }
  log "up-to-date: colorscripts @ $(repo_commit) at $INSTALLED_BIN"
  exit 0
fi

# 2. Ensure the shallow clone exists; update it when COLORSCRIPTS_UPDATE is set.
command -v git >/dev/null 2>&1 || die "git not found on PATH"
if [[ -d "$REPO/.git" ]]; then
  if [[ -n "${COLORSCRIPTS_UPDATE:-}" ]]; then
    log "updating clone to latest $REF"
    # Shallow clones choke on `git pull` (it backfills history); fetch + reset
    # is the safe pattern.
    git -C "$REPO" fetch --depth 1 --quiet origin "$REF"
    git -C "$REPO" reset --hard --quiet FETCH_HEAD
  fi
else
  log "shallow-cloning shell-color-scripts ($REF) into $REPO"
  mkdir -p -- "$BUILD_ROOT"
  git clone --depth 1 --branch "$REF" --quiet "$URL" "$REPO" || die "git clone failed"
fi
commit="$(repo_commit)"

# 3. Install: verbatim copy of the CLI + the colorscripts data dir into PREFIX.
#    There's no compile step — these are shell scripts — so "install" is a
#    copy, then the one-line patch below. rm -rf first so a stale data script
#    removed upstream doesn't linger.
log "installing into $PREFIX"
rm -rf "$PREFIX"
mkdir -p -- "$PREFIX/bin" "$INSTALLED_DATA"
cp -- "$REPO/colorscript.sh" "$INSTALLED_BIN"
chmod +x "$INSTALLED_BIN"
cp -R -- "$REPO/colorscripts/." "$INSTALLED_DATA/"

# 4. Patch the static data dir reference. Upstream line 8 hardcodes
#    /opt/shell-color-scripts/colorscripts; redirect it to this user-owned
#    install. $HOME expands at runtime, so the patched script stays correct
#    regardless of who invokes it (per-user install). The DEV branch
#    (`./colorscripts`, used for upstream hacking) is left untouched.
log "patching DIR_COLORSCRIPTS -> $INSTALLED_DATA"
if ! grep -qF -- "$STATIC_PATH" "$INSTALLED_BIN"; then
  die "upstream layout changed: '$STATIC_PATH' not found in $INSTALLED_BIN — update the patch"
fi
perl -0pi -e 's{DIR_COLORSCRIPTS="/opt/shell-color-scripts/colorscripts"}{DIR_COLORSCRIPTS="\$HOME/.local/opt/colorscripts/share/colorscripts"}' "$INSTALLED_BIN"

grep -qF -- "$PATCHED_PATH" "$INSTALLED_BIN" \
  || die "patch failed: DIR_COLORSCRIPTS not rewritten in $INSTALLED_BIN"

printf '%s\n' "$commit" > "$STAMP"

relink

# 5. Self-test: the exact invocation nvim's dashboard uses must succeed.
if "$INSTALLED_BIN" -e square >/dev/null 2>&1; then
  log "installed colorscripts @ $commit"
  log "linked $BINLINK -> $INSTALLED_BIN"
else
  die "post-install self-test failed: 'colorscript -e square' returned non-zero"
fi
