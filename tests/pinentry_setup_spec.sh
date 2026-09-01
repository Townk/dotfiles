# Tests for home/dot_local/bin/executable_system-pinentry-setup — the
# converger for the signing/keychain half of the password stack.
#
# Scope is the guard rail, which is the part that must never be wrong: the
# script's later steps mint certificates, talk to the real keychain and raise
# consent dialogs, so every case here must exit BEFORE reaching them. That is
# also why the fake $HOME carries a stub common.zsh and a stub presence
# helper: with those two seams the guards are fully decidable without the
# script ever touching `security`, `codesign` or gpg. The acting steps are
# exercised live instead (they are dialogs and keychain state — nothing a
# suite can assert), per the same reasoning pinentry_auto_spec.sh records for
# Touch ID.
#
# Skipped off macOS: the script's first guard is a real `uname`, and the only
# way past it from Linux would be an override that exists solely for this
# file.
Describe 'system-pinentry-setup guards'
  SETUP="home/dot_local/bin/executable_system-pinentry-setup"

  Skip if "the script is Darwin-only by its first guard" [ "$(uname -s)" != Darwin ]

  setup() {
    PS_HOME=$(mktemp -d)
    mkdir -p "$PS_HOME/.local/lib" "$PS_HOME/.local/libexec"
    cat >"$PS_HOME/.local/lib/common.zsh" <<'EOS'
log_info() { echo "INFO: $*"; }
log_warn() { echo "WARN: $*" >&2; }
log_ok()   { echo "OK: $*"; }
EOS
  }
  cleanup() { rm -rf "$PS_HOME"; unset PS_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  presence_says() {
    printf '#!/bin/sh\necho %s\n' "$1" >"$PS_HOME/.local/libexec/presence"
    chmod +x "$PS_HOME/.local/libexec/presence"
  }

  run_setup() { env HOME="$PS_HOME" zsh "$SETUP"; }

  It 'skips quietly when nobody is at the console'
    presence_says remote
    When call run_setup
    The output should include "nobody at the console"
    The status should be success
  End

  It 'skips quietly when the presence helper is missing'
    When call run_setup
    The output should include "nobody at the console"
    The status should be success
  End

  It 'skips with a warning when pinentry-ui is not built'
    presence_says touchid
    When call run_setup
    The stderr should include "pinentry-ui not built"
    The status should be success
  End
End
