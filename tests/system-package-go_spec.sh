# Regression test: an inherited GOROOT must not outvote the toolchain binary.
#
# mise exports GOROOT pinned to the version active when the parent shell
# loaded. `system-update` converges mise (upgrade + prune) BEFORE the package
# sync, which deletes that directory — and system-package-go then invokes the
# toolchain binary DIRECTLY ("$(go env GOROOT)/bin/go", skipping the shim that
# would re-resolve the env per invocation), so every `go install` inherited
# the stale GOROOT and failed with "go: cannot find GOROOT directory". The
# worker now unsets GOROOT at startup: go derives its root from the resolved
# executable, always the toolchain actually in use.
Describe 'system-package-go: sync with a stale inherited GOROOT'
  WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-go"

  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-go.XXXXXX")"
    mkdir -p "$STAGE/home/.local" "$STAGE/shimbin" "$STAGE/goroot/bin" \
      "$STAGE/packages" "$STAGE/gopath/bin"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"

    # Stub `go`, installed as BOTH the PATH shim and the toolchain binary the
    # worker resolves through `go env GOROOT`. The shim side answers env
    # queries; the direct-binary `install` fails the way real go does when
    # GOROOT names a root that is not its own — the failure mode of an
    # inherited GOROOT pointing into a pruned mise install.
    cat >"$STAGE/shimbin/go" <<'SH'
#!/bin/sh
case "$1 $2" in
  "env GOBIN")  exit 0 ;;  # empty: worker falls back to GOPATH/bin
  "env GOROOT") printf '%s\n' "$STUB_GOROOT"; exit 0 ;;
  "env GOPATH") printf '%s\n' "$STUB_GOPATH"; exit 0 ;;
esac
case "$1" in
  version) exit 1 ;;  # no module metadata for stray files
  install)
    if [ -n "${GOROOT:-}" ]; then
      echo "go: cannot find GOROOT directory: $GOROOT" >&2
      exit 2
    fi
    printf '%s\n' "$2" >>"$STUB_INSTALL_LOG"
    exit 0 ;;
esac
exit 0
SH
    chmod +x "$STAGE/shimbin/go"
    cp "$STAGE/shimbin/go" "$STAGE/goroot/bin/go"

    print -r -- 'example.com/mod/cmd/tool' >"$STAGE/packages/Gofile"
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_sync() {
    # env -i: the spec process itself runs under a mise-activated shell whose
    # GOROOT/MISE_* must not leak in — GOROOT below is the variable under test.
    env -i HOME="$STAGE/home" \
      PATH="$STAGE/shimbin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_GOROOT="$STAGE/goroot" STUB_GOPATH="$STAGE/gopath" \
      STUB_INSTALL_LOG="$STAGE/installed.log" \
      GOROOT="$STAGE/pruned/go/1.27.0" \
      zsh "$WORKER" sync
  }

  It 'installs declared modules despite the stale GOROOT'
    When call run_sync
    The status should be success
    The stdout should include "Syncing go binaries"
    The stderr should not include "cannot find GOROOT"
    The stderr should not include "failed to install"
    The contents of file "$STAGE/installed.log" should include "example.com/mod/cmd/tool@latest"
  End
End
