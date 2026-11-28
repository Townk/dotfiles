# system-package-npm — sync exit status.
#
# A failed INSTALL of a declared-but-missing global must fail the sync (the
# dispatcher then reports it and system-update stops), exactly as the snap
# worker does — but only after the rest of the sync has run. Update and
# uninstall failures keep warning only. npm is a stub binary on PATH whose
# global tree is a JSON state file.
Describe 'system-package-npm: sync exit status'
  WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-npm"

  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-npm-sync.XXXXXX")"
    mkdir -p "$STAGE/home/.local" "$STAGE/bin" "$STAGE/packages"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"
    # The worker (and the stub) need jq, which is not always in /usr/bin.
    ln -s "$(command -v jq)" "$STAGE/bin/jq"

    # `npm ls -g` prints the state file, `npm outdated -g` reports `present`
    # as behind (so the update step always has work), `npm root -g` names a
    # directory that does not exist (no post-install build). Everything else
    # is logged: `npm install -g --no-fund <spec>` fails for
    # $STUB_FAIL_INSTALL, otherwise records the package; `npm update` /
    # `npm uninstall` exit with their knobs.
    cat >"$STAGE/bin/npm" <<'SH'
#!/bin/sh
case "$1" in
  ls) cat "$STUB_STATE"; exit 0 ;;
  outdated) echo '{"present":{"current":"1.0.0","latest":"2.0.0"}}'; exit 1 ;;
  root) printf '%s\n' "$STUB_ROOT"; exit 0 ;;
esac
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  install)
    if [ "$4" = "${STUB_FAIL_INSTALL:-}" ]; then
      echo "npm error 404 Not Found: $4" >&2
      exit 1
    fi
    jq --arg n "$4" '.dependencies[$n] = {version: "1.0.0"}' "$STUB_STATE" >"$STUB_STATE.new" &&
      mv "$STUB_STATE.new" "$STUB_STATE"
    ;;
  update) exit "${STUB_UPDATE_RC:-0}" ;;
  uninstall) exit "${STUB_UNINSTALL_RC:-0}" ;;
esac
exit 0
SH
    chmod +x "$STAGE/bin/npm"
    print -r -- '{"dependencies":{"npm":{"version":"11.0.0"},"present":{"version":"1.0.0"}}}' >"$STAGE/state.json"
    : >"$STAGE/npm.log"
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_sync() {   # run_sync <package whose install fails> <update rc> <uninstall rc>
    env -i HOME="$STAGE/home" \
      PATH="$STAGE/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_STATE="$STAGE/state.json" STUB_LOG="$STAGE/npm.log" STUB_ROOT="$STAGE/root" \
      STUB_FAIL_INSTALL="$1" STUB_UPDATE_RC="${2:-0}" STUB_UNINSTALL_RC="${3:-0}" \
      zsh "$WORKER" sync
  }

  It 'fails when a declared-but-missing package cannot be installed, after finishing the sync'
    printf 'missing\npresent\n' >"$STAGE/packages/Npmfile"
    When call run_sync missing
    The status should be failure
    The stderr should include "failed to install missing"
    # The update step and the changes report still ran.
    The contents of file "$STAGE/npm.log" should include "update -g --no-fund --silent present"
    The stdout should include "1 package already up to date"
  End

  It 'succeeds when the missing packages install'
    printf 'missing\nspecced -- git+https://example.com/specced.git\npresent\n' >"$STAGE/packages/Npmfile"
    When call run_sync ""
    The status should be success
    The stdout should include "missing installed: 1.0.0"
    The stdout should not include "="
    The contents of file "$STAGE/npm.log" should include "install -g --no-fund missing"
    The contents of file "$STAGE/npm.log" should include "install -g --no-fund git+https://example.com/specced.git"
  End

  It 'succeeds when only the update and an uninstall fail'
    print -r -- '{"dependencies":{"extra":{"version":"3.0.0"},"present":{"version":"1.0.0"}}}' >"$STAGE/state.json"
    printf 'present\n' >"$STAGE/packages/Npmfile"
    When call run_sync "" 1 1
    The status should be success
    The stdout should include "Syncing npm globals"
    The stderr should include "failed to uninstall extra"
    The stderr should not include "failed to install"
    The contents of file "$STAGE/npm.log" should include "update -g --no-fund --silent present"
  End
End
