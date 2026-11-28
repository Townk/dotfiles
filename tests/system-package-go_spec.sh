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
  Skip if 'complete-only: runs a whole system-package-go sync against stub tools (dozens of forks)' spec_complete_only
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
  # The worker's spinner naps 0.1 s per tick beside each install
  # (spin::nap -> common::sleep): on the virtual clock the ticks cost nothing.
  # The stubs' pooled inodes are exec'd once here, not inside an example.
  Include tests/exec_warm_helper.sh
  once() { spec_clock_set && spec_exec_pool_warm 2; }
  BeforeAll 'once'
  BeforeEach 'setup'

  run_sync() {
    # env -i: the spec process itself runs under a mise-activated shell whose
    # GOROOT/MISE_* must not leak in — GOROOT below is the variable under test.
    env -i HOME="$STAGE/home" TMPDIR="$TMPDIR" COMMON_CLOCK_FILE="$COMMON_CLOCK_FILE" \
      PATH="$STAGE/shimbin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_GOROOT="$STAGE/goroot" STUB_GOPATH="$STAGE/gopath" \
      STUB_INSTALL_LOG="$STAGE/installed.log" \
      GOROOT="$STAGE/pruned/go/1.27.0" \
      zsh -f "$WORKER" sync
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

# A failed INSTALL of a declared-but-missing module must fail the sync (the
# dispatcher then reports it and system-update stops), exactly as the snap
# worker does — but only after the rest of the sync has run. Upgrade failures
# keep warning only.
Describe 'system-package-go: sync exit status'
  Skip if 'complete-only: runs a whole system-package-go sync against stub tools (dozens of forks)' spec_complete_only
  WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-go"

  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-go-sync.XXXXXX")"
    mkdir -p "$STAGE/home/.local" "$STAGE/shimbin" "$STAGE/goroot/bin" \
      "$STAGE/packages" "$STAGE/gopath/bin"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"

    # Stub `go` (PATH shim AND toolchain binary). `go version -m <file>`
    # answers from a "<file>.meta" sidecar, so a binary counts as installed
    # only when the example staged one. `go install` logs every attempt and
    # fails when $STUB_FAIL_INSTALL is set.
    cat >"$STAGE/shimbin/go" <<'SH'
#!/bin/sh
case "$1 $2" in
  "env GOBIN")  exit 0 ;;  # empty: worker falls back to GOPATH/bin
  "env GOROOT") printf '%s\n' "$STUB_GOROOT"; exit 0 ;;
  "env GOPATH") printf '%s\n' "$STUB_GOPATH"; exit 0 ;;
esac
case "$1" in
  version)
    [ -f "$3.meta" ] || exit 1
    cat "$3.meta"
    exit 0 ;;
  install)
    printf '%s\n' "$2" >>"$STUB_INSTALL_LOG"
    if [ -n "${STUB_FAIL_INSTALL:-}" ]; then
      echo "go: $2: module lookup failed" >&2
      exit 1
    fi
    exit 0 ;;
esac
exit 0
SH
    chmod +x "$STAGE/shimbin/go"
    cp "$STAGE/shimbin/go" "$STAGE/goroot/bin/go"

    print -r -- 'example.com/mod/cmd/tool' >"$STAGE/packages/Gofile"
  }
  # The worker's spinner naps 0.1 s per tick beside each install
  # (spin::nap -> common::sleep): on the virtual clock the ticks cost nothing.
  # The stubs' pooled inodes are exec'd once here, not inside an example.
  Include tests/exec_warm_helper.sh
  once() { spec_clock_set && spec_exec_pool_warm 2; }
  BeforeAll 'once'
  BeforeEach 'setup'

  # Stage example.com/mod/cmd/tool as already installed. The .meta sidecar is
  # not executable, so the worker's scan of $GOBIN skips it.
  stage_installed() {
    print -r -- '#!/bin/sh' >"$STAGE/gopath/bin/tool"
    chmod +x "$STAGE/gopath/bin/tool"
    printf '%s\n' "$STAGE/gopath/bin/tool: go1.27.0" \
      "	path	example.com/mod/cmd/tool" \
      "	mod	example.com/mod	v1.0.0	h1:x=" >"$STAGE/gopath/bin/tool.meta"
  }

  run_sync() {   # run_sync <non-empty to make every `go install` fail>
    env -i HOME="$STAGE/home" TMPDIR="$TMPDIR" COMMON_CLOCK_FILE="$COMMON_CLOCK_FILE" \
      PATH="$STAGE/shimbin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_GOROOT="$STAGE/goroot" STUB_GOPATH="$STAGE/gopath" \
      STUB_INSTALL_LOG="$STAGE/installed.log" STUB_FAIL_INSTALL="$1" \
      zsh -f "$WORKER" sync
  }

  It 'fails when a declared-but-missing module cannot be installed, after finishing the sync'
    When call run_sync 1
    The status should be failure
    The stdout should include "Syncing go binaries"
    The stderr should include "failed to install example.com/mod/cmd/tool"
    # The upgrade pass still ran: a second `go install` attempt was made.
    The stderr should include "failed to upgrade example.com/mod/cmd/tool"
    The contents of file "$STAGE/installed.log" should equal "example.com/mod/cmd/tool@latest
example.com/mod/cmd/tool@latest"
  End

  It 'succeeds when the missing module installs'
    When call run_sync ""
    The status should be success
    The stdout should include "Syncing go binaries"
    The stderr should not include "failed to"
  End

  It 'succeeds when only an upgrade fails'
    stage_installed
    When call run_sync 1
    The status should be success
    The stdout should include "1 binary already up to date"
    The stderr should include "failed to upgrade example.com/mod/cmd/tool"
    The stderr should not include "failed to install"
  End
End
