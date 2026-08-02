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

# Staging + backup siblings of $PREFIX (same filesystem, so mv is atomic). The
# CLI + data are copied AND self-tested in $STAGE, then atomically swapped over
# the live $PREFIX; the previous tree is parked in $BACKUP for rollback. The
# live $PREFIX is never removed before a validated replacement is in place.
STAGE="${COLORSCRIPTS_STAGE:-$PREFIX.new}"
BACKUP="${COLORSCRIPTS_BACKUP:-$PREFIX.old}"

STATIC_PATH='DIR_COLORSCRIPTS="/opt/shell-color-scripts/colorscripts"'
# Patched form honors a DIR_COLORSCRIPTS env override (falling back to the final
# per-user path), so the staged CLI can be self-tested against the STAGED data
# dir before the swap, while normal callers (nvim's dashboard) still resolve the
# installed data with no env set.
PATCHED_PATH='DIR_COLORSCRIPTS="${DIR_COLORSCRIPTS:-$HOME/.local/opt/colorscripts/share/colorscripts}"'

log() { printf '[colorscripts-build] %s\n' "$*"; }
die() { printf '[colorscripts-build] error: %s\n' "$*" >&2; exit 1; }
repo_commit() { git -C "$REPO" rev-parse --short HEAD 2>/dev/null; }
relink() { mkdir -p -- "$(dirname "$BINLINK")"; ln -sfn "$INSTALLED_BIN" "$BINLINK"; }

# install_stage <dir> — copy the CLI + colorscripts data into <dir> (bin/ +
# share/colorscripts/) and apply the DIR_COLORSCRIPTS patch. Returns non-zero
# (leaving the caller to discard <dir>) if the upstream layout changed or the
# patch did not take. Split out as a seam so the atomic swap can be unit-tested
# with the real copy stubbed.
install_stage() {
  local dir="$1" bin="$1/bin/colorscript" data="$1/share/colorscripts"
  mkdir -p -- "$dir/bin" "$data"
  cp -- "$REPO/colorscript.sh" "$bin"
  chmod +x "$bin"
  cp -R -- "$REPO/colorscripts/." "$data/"

  # Patch the static /opt data dir to a DIR_COLORSCRIPTS-overridable per-user
  # path (see PATCHED_PATH). $HOME/$DIR_COLORSCRIPTS expand at runtime.
  if ! grep -qF -- "$STATIC_PATH" "$bin"; then
    log "upstream layout changed: '$STATIC_PATH' not found in $bin — update the patch"
    return 1
  fi
  perl -0pi -e 's{DIR_COLORSCRIPTS="/opt/shell-color-scripts/colorscripts"}{DIR_COLORSCRIPTS="\${DIR_COLORSCRIPTS:-\$HOME/.local/opt/colorscripts/share/colorscripts}"}' "$bin"
  if ! grep -qF -- "$PATCHED_PATH" "$bin"; then
    log "patch failed: DIR_COLORSCRIPTS not rewritten in $bin"
    return 1
  fi
}

# validate_stage <dir> — return 0 iff the CLI at <dir> passes the exact self-test
# nvim's dashboard uses (`colorscript -e square`), reading the colocated STAGED
# data via the DIR_COLORSCRIPTS override. Reused after the swap (pointed at the
# in-place data) as the authoritative gate before the backup is dropped.
validate_stage() {
  local dir="$1" bin="$1/bin/colorscript" data="$1/share/colorscripts"
  [[ -x "$bin" ]] || return 1
  DIR_COLORSCRIPTS="$data" "$bin" -e square >/dev/null 2>&1
}

# stage_and_swap — install into $STAGE, validate there, then atomically replace
# $PREFIX, keeping $BACKUP for rollback. The live $PREFIX is only moved aside
# (never removed) and is restored on any failure, so a stale/renamed upstream
# script or a failed self-test can never leave nvim without a working
# colorscript. Relies on install_stage + validate_stage (both stubbable).
stage_and_swap() {
  rm -rf -- "$STAGE" "$BACKUP"

  if ! install_stage "$STAGE"; then
    rm -rf -- "$STAGE"
    die "install into staging prefix failed; live install left intact"
  fi
  if ! validate_stage "$STAGE"; then
    rm -rf -- "$STAGE"
    die "staged self-test ('colorscript -e square') failed; live install left intact"
  fi

  if [[ -e "$PREFIX" ]]; then
    mv -- "$PREFIX" "$BACKUP" || die "could not park live prefix; live install left intact"
  fi
  if ! mv -- "$STAGE" "$PREFIX"; then
    [[ -e "$BACKUP" ]] && mv -- "$BACKUP" "$PREFIX"
    die "could not move staged install into place; rolled back to previous install"
  fi

  # Authoritative post-swap re-validation against the in-place tree.
  if ! validate_stage "$PREFIX"; then
    rm -rf -- "$PREFIX"
    [[ -e "$BACKUP" ]] && mv -- "$BACKUP" "$PREFIX"
    die "post-swap self-test failed; rolled back to previous install"
  fi
  rm -rf -- "$BACKUP"
}

# main — the install pipeline. Wrapped so specs can source this file to
# unit-test stage_and_swap with install/validate stubbed, without a real clone.
main() {
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

# 3. Install: verbatim copy of the CLI + the colorscripts data dir, patched, into
#    a STAGING prefix; self-test it there; then atomically swap it over the live
#    $PREFIX with rollback. There's no compile step — these are shell scripts —
#    so "install" is a copy + one-line patch, all done in staging so a stale/
#    removed-upstream data script or a failed self-test never destroys the live
#    install before its validated replacement is in place.
log "installing + self-testing into staging prefix, then swapping"
stage_and_swap

printf '%s\n' "$commit" > "$STAMP"
relink

log "installed colorscripts @ $commit"
log "linked $BINLINK -> $INSTALLED_BIN"
}

# Run the pipeline only when executed, not when sourced (specs source this file
# to unit-test stage_and_swap with install/validate stubbed).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
