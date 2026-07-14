# Mount-capable rclone

The official rclone binary from [downloads.rclone.org](https://downloads.rclone.org),
installed instead of Homebrew's, because Homebrew's build cannot mount.

## Why not brew

A live smoke test proved Homebrew's `rclone` formula hard-refuses `rclone
mount` on macOS:

```
rclone mount is not supported on MacOS when rclone is installed via Homebrew
```

There's no cask either. `go install github.com/rclone/rclone` also doesn't
help — the cgo `cmount` backend needs `CGO_ENABLED=1` and macFUSE's headers
at build time, which a plain `go install` doesn't set up. Only upstream's own
release build links it in, so that's the source of truth here.

This is what backs the clipboard-mount peer-clipboard SFTP mount over
macFUSE (`cask 'macfuse'` in `Brewfile.tmpl`) — mount support is why this
tool exists in this repo at all; anything that only needed `rclone sync`
could just use brew's.

## Layout

- `install-rclone.sh` — the installer: bash, fetches the pinned-version zip
  + its `SHA256SUMS`, verifies the checksum before unzipping, and installs.
  Idempotent — a no-op fast path once the pinned version is already linked.
- `home/.chezmoiscripts/run_onchange_after_52-custom-build-rclone.sh.tmpl`
  runs the installer on `chezmoi apply`, for the **macOS personal profile
  only** (mount support is coupled to macFUSE, which is personal-only —
  see the Brewfile). It re-fires when `install-rclone.sh` changes (its SHA
  is baked into the rendered hook).

Installed to `~/.local/opt/rclone/` (binary + the zip's man page / README /
git-log.txt), symlinked from `~/.local/bin/rclone`.

## Update procedure

Bump `RCLONE_VERSION` at the top of `install-rclone.sh` and apply — editing
the file changes its SHA, so the `run_onchange` hook re-fires and installs
the new pinned version (verified against its own `SHA256SUMS` entry same as
any other install). There's no "latest" tracking by design: unlike the zsh
build (a git clone with an `_UPDATE=1` escape hatch), this is a versioned
release artifact, so a version bump is the only update path — matching how
every other pinned dependency in this repo is bumped.

## Verifying it's actually the mount-capable build

Homebrew's build refuses before ever touching FUSE:

```
rclone mount is not supported on MacOS when rclone is installed via Homebrew
```

This build instead reaches macFUSE and fails there when the kext isn't
loaded (expected on a machine that hasn't triggered the System Extension
approval yet):

```
mount_macfuse: the file system is not available (1)
```

That different failure point is the proof the binary is mount-capable.
