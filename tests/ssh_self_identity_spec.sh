# run_after_09-render-ssh-self-identity: renders the LOOSE sender fragment
# ~/.ssh/config.d/00-self-identity.conf from this machine's ~/.hostname-alias
# and clipboard key (peer-alias spec H2). The template has no data
# dependencies, so setup renders it once and each example runs it in an
# isolated $HOME with a sandboxed self-name file.
Describe 'ssh self-identity sender'
  # Stubs an example makes executable run from pooled inodes (spec_helper.sh):
  # their first exec is paid here, once, not inside the first examples.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 2'
  SRC="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_after_09-render-ssh-self-identity.sh.tmpl"

  # The template has no per-example input: rendered once, and run once
  # against a scratch HOME (an inode's first exec is charged by macOS). Each
  # example runs a hard link to it from its own directory.
  render_once() {
    SELF_ID_FIX="$SHELLSPEC_TMPBASE/self-id-fix"
    mkdir -p "$SELF_ID_FIX/home"
    chezmoi execute-template <"$SRC" >"$SELF_ID_FIX/self-identity.sh" || return 1
    chmod +x "$SELF_ID_FIX/self-identity.sh"
    HOME="$SELF_ID_FIX/home" XDG_STATE_HOME="$SELF_ID_FIX/home/.local/state" \
      "$SELF_ID_FIX/self-identity.sh" >/dev/null 2>&1
    return 0
  }
  BeforeAll 'render_once'
  setup() {
    TEST_TMP=$(mktemp -d "$SHELLSPEC_TMPBASE/self-id.XXXXXX")
    export HOME="$TEST_TMP/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME/.ssh/config.d" "$XDG_STATE_HOME/clipboard"
    printf 'peer-key-01\n' >"$XDG_STATE_HOME/clipboard/self-name"
    export SELF_IDENTITY_CORE_LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/clipboard-store-core.zsh"
    RENDERED="$TEST_TMP/self-identity.sh"
    ln "$SELF_ID_FIX/self-identity.sh" "$RENDERED"
    FRAG="$HOME/.ssh/config.d/00-self-identity.conf"
  }
  BeforeEach 'setup'

  It 'renders the SetEnv line from the alias file and the clipboard key'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    run() { "$RENDERED" 2>/dev/null; cat "$FRAG"; }
    When call run
    The line 1 of output should equal '# Written by chezmoi run_after_09 from ~/.hostname-alias — do not edit.'
    The line 2 of output should equal 'SetEnv LC_ORIGIN_HOST=peer-key-01 LC_ORIGIN_ALIAS=peer-laptop'
  End

  It 'writes the fragment with mode 600'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    When call sh -c 'ls -l "$1" | cut -c1-10' _ "$FRAG"
    The output should equal '-rw-------'
  End

  # Review Focus: a Windows-edited or padded alias file.
  It 'trims CRLF and trailing space from the alias file'
    printf 'peer-laptop  \r\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    When call sed -n 2p "$FRAG"
    The output should equal 'SetEnv LC_ORIGIN_HOST=peer-key-01 LC_ORIGIN_ALIAS=peer-laptop'
  End

  # Under a UTF-8 locale bash 3.2 (macOS /bin/sh) matches A-Za-z by collation.
  It 'refuses a non-ASCII alias under a UTF-8 locale'
    printf 'péer\n' >"$HOME/.hostname-alias"
    printf 'stale\n' >"$FRAG"
    LC_ALL=en_US.UTF-8 "$RENDERED" 2>/dev/null
    When call test -e "$FRAG"
    The status should be failure
  End

  # A leftover temp file inside config.d would be parsed by `Include config.d/*`.
  It 'leaves no temp file behind when the final move fails'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    mkdir -p "$TEST_TMP/failbin"
    printf '#!/bin/sh\nexit 1\n' >"$TEST_TMP/failbin/mv"
    chmod +x "$TEST_TMP/failbin/mv"
    PATH="$TEST_TMP/failbin:$PATH" "$RENDERED" 2>/dev/null || true
    When call ls -A "$HOME/.ssh/config.d"
    The output should equal ''
  End

  It 'creates config.d private (0700) when it is missing'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    rm -rf "$HOME/.ssh"
    "$RENDERED" 2>/dev/null
    When call sh -c 'ls -ld "$1" | cut -c1-10' _ "$HOME/.ssh/config.d"
    The output should equal 'drwx------'
  End

  It 'removes the fragment when there is no alias file'
    printf 'stale\n' >"$FRAG"
    "$RENDERED" 2>/dev/null
    When call test -e "$FRAG"
    The status should be failure
  End

  It 'removes the fragment when the alias is invalid'
    printf 'two words\n' >"$HOME/.hostname-alias"
    printf 'stale\n' >"$FRAG"
    "$RENDERED" 2>/dev/null
    When call test -e "$FRAG"
    The status should be failure
  End

  It 'does not rewrite an unchanged fragment'
    printf 'peer-laptop\n' >"$HOME/.hostname-alias"
    "$RENDERED" 2>/dev/null
    touch -t 200001010000 "$FRAG"; touch -t 200001010001 "$TEST_TMP/ref"
    "$RENDERED" 2>/dev/null
    When call find "$FRAG" -newer "$TEST_TMP/ref"
    The output should equal ''
  End

  # The whole point of rendering on the machine: no host value in the SOURCE.
  It 'keeps every host value out of the source template'
    When call grep -c -E 'peer-key-01|peer-laptop' "$SRC"
    The output should equal '0'
    The status should be failure
  End
End
