#!/usr/bin/env bash
# install-rclone.sh — install the OFFICIAL rclone binary (mount-capable).
#
# Why this exists
# ----------------
# Homebrew's rclone formula is built WITHOUT the cgo cmount backend, so
# `rclone mount` hard-refuses on macOS:
#   "rclone mount is not supported on MacOS when rclone is installed via Homebrew"
# There is no cask, and `go install` also lacks the cgo cmount backend (it
# needs CGO_ENABLED=1 + macFUSE headers at build time, which upstream's own
# release pipeline provides but a plain `go install` does not). The only
# build that mounts is the official binary from downloads.rclone.org — the
# source the user sanctioned for this tool.
#
# What this does
# --------------
# Downloads the pinned-version zip + its SHA256SUMS, verifies the zip's
# checksum BEFORE unzipping, installs the archive's contents into
# ~/.local/opt/rclone, and symlinks the binary into ~/.local/bin. Re-running
# is a fast, network-free no-op once that version is already in place.

set -euo pipefail

RCLONE_VERSION="1.74.4"

PREFIX="${RCLONE_BUILD_PREFIX:-$HOME/.local/opt/rclone}"
BINLINK="${RCLONE_BUILD_BINLINK:-$HOME/.local/bin/rclone}"
RCLONE_BIN="$PREFIX/rclone"
BASE_URL="https://downloads.rclone.org/v${RCLONE_VERSION}"

log() { printf '[rclone-install] %s\n' "$*"; }
die() { printf '[rclone-install] error: %s\n' "$*" >&2; exit 1; }

installed_version() { "$1" version 2>/dev/null | head -1 | awk '{print $2}'; }
relink() { mkdir -p -- "$(dirname "$BINLINK")"; ln -sfn "$RCLONE_BIN" "$BINLINK"; }

# 1. Fast path: already installed at the pinned version, symlink correct.
#    Fully offline — no network hit when there's nothing to do.
if [[ -x "$RCLONE_BIN" \
      && "$(installed_version "$RCLONE_BIN")" == "v$RCLONE_VERSION" \
      && "$(readlink "$BINLINK" 2>/dev/null)" == "$RCLONE_BIN" ]]; then
  log "up-to-date: rclone v$RCLONE_VERSION at $RCLONE_BIN"
  exit 0
fi

# 2. Map uname -m to rclone's macOS asset naming.
case "$(uname -m)" in
  arm64)  ARCH="arm64" ;;
  x86_64) ARCH="amd64" ;;
  *)      die "unsupported architecture: $(uname -m)" ;;
esac

ZIP_NAME="rclone-v${RCLONE_VERSION}-osx-${ARCH}.zip"

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v unzip >/dev/null 2>&1 || die "unzip not found on PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "fetching $ZIP_NAME"
curl -fsSL -o "$WORK/$ZIP_NAME" "$BASE_URL/$ZIP_NAME" \
  || die "download failed: $BASE_URL/$ZIP_NAME"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
  || die "download failed: $BASE_URL/SHA256SUMS"

# 3. Verify BEFORE unzipping. SHA256SUMS is a PGP clearsigned file covering
#    every platform's asset; pull just our entry and compare it against a
#    fresh hash of the file actually on disk (not a copy/paste of the sum).
expected="$(grep -F "  $ZIP_NAME" "$WORK/SHA256SUMS" | awk '{print $1}')"
[[ -n "$expected" ]] || die "no SHA256SUMS entry for $ZIP_NAME"
actual="$(shasum -a 256 "$WORK/$ZIP_NAME" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] \
  || die "checksum mismatch for $ZIP_NAME (expected $expected, got $actual)"
log "checksum verified ($actual)"

# 4. Unpack and install: the zip's one top-level directory's CONTENTS become
#    ~/.local/opt/rclone (binary, man page, README, git-log.txt). Blow away
#    any previous install first — atomic enough for a single-user CLI tool.
log "unzipping"
unzip -q "$WORK/$ZIP_NAME" -d "$WORK/extracted" || die "unzip failed"
extracted_dir="$WORK/extracted/rclone-v${RCLONE_VERSION}-osx-${ARCH}"
[[ -d "$extracted_dir" ]] || die "expected directory not found in zip: $extracted_dir"

rm -rf "$PREFIX"
mkdir -p -- "$PREFIX"
cp -R "$extracted_dir"/. "$PREFIX"/
chmod 755 "$RCLONE_BIN"

# curl-fetched binaries can carry com.apple.quarantine; Gatekeeper would
# block a CLI on first run. Best-effort: not every machine sets it, and a
# missing attribute is not an error.
xattr -dr com.apple.quarantine "$PREFIX" 2>/dev/null || true

relink

# 5. Post-install self-test.
installed="$(installed_version "$BINLINK")"
[[ "$installed" == "v$RCLONE_VERSION" ]] \
  || die "post-install version check failed: got '$installed', expected 'v$RCLONE_VERSION'"

log "installed rclone $installed @ $RCLONE_BIN"
log "linked $BINLINK -> $RCLONE_BIN"
